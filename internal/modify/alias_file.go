package modify

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-message/textproto"
	"github.com/foxcpp/maddy/internal/address"
	"github.com/foxcpp/maddy/internal/buffer"
	"github.com/foxcpp/maddy/internal/config"
	"github.com/foxcpp/maddy/internal/hooks"
	"github.com/foxcpp/maddy/internal/log"
	"github.com/foxcpp/maddy/internal/module"
)

const ModName = "alias_file"

type Modifier struct {
	instName string
	files    []string

	aliases      map[string]string
	aliasesLck   sync.RWMutex
	aliasesStamp time.Time

	stopReloader chan struct{}
	forceReload  chan struct{}

	log log.Logger
}

func New(_, instName string, _, inlineArgs []string) (module.Module, error) {
	return &Modifier{
		instName:     instName,
		files:        inlineArgs,
		aliases:      make(map[string]string),
		stopReloader: make(chan struct{}),
		forceReload:  make(chan struct{}),
		log:          log.Logger{Name: ModName},
	}, nil
}

func (m *Modifier) Name() string {
	return ModName
}

func (m *Modifier) InstanceName() string {
	return m.instName
}

func (m *Modifier) Init(cfg *config.Map) error {
	var filesCfg []string
	cfg.Bool("debug", true, false, &m.log.Debug)
	cfg.StringList("files", false, false, []string{}, &filesCfg)

	if _, err := cfg.Process(); err != nil {
		return err
	}

	m.files = append(m.files, filesCfg...)
	if len(m.files) == 0 {
		return fmt.Errorf("%s: at least one aliases file is required", ModName)
	}

	m.aliasesStamp = time.Now()
	for _, file := range m.files {
		if err := readFile(file, m.aliases); err != nil {
			if os.IsNotExist(err) {
				m.log.Printf("ignoring non-existent file: %s", file)
				continue
			}
			return err
		}
	}

	go m.aliasesReloader()
	hooks.AddHook(hooks.EventReload, func() {
		m.forceReload <- struct{}{}
	})

	return nil
}

var reloadInterval = 15 * time.Second

func (m *Modifier) aliasesReloader() {
	defer func() {
		if err := recover(); err != nil {
			stack := debug.Stack()
			log.Printf("panic during aliases reload: %v\n%s", err, stack)
		}
	}()

	// TODO: Review the possibility of using inotify or similar mechanisms.
	t := time.NewTicker(reloadInterval)

	for {
		select {
		case <-t.C:
			var (
				latestStamp   time.Time
				filesRemoved  bool
				filesExisting bool
			)
			for _, file := range m.files {
				info, err := os.Stat(file)
				if err != nil {
					if os.IsNotExist(err) {
						filesRemoved = true
						continue
					}
					m.log.Printf("%v", err)
					continue
				}

				filesExisting = true
				if info.ModTime().After(latestStamp) {
					latestStamp = info.ModTime()
				}
			}

			if !latestStamp.After(m.aliasesStamp) && !filesRemoved {
				continue
			}
			if !filesExisting {
				m.aliasesLck.Lock()
				m.aliases = map[string]string{}
				m.aliasesStamp = time.Now()
				m.aliasesLck.Unlock()
				continue
			}
		case <-m.forceReload:
		case <-m.stopReloader:
			m.stopReloader <- struct{}{}
			return
		}

		m.log.Debugf("reloading aliases")

		newAliases := make(map[string]string, len(m.aliases)+5)

		for _, file := range m.files {
			if err := readFile(file, newAliases); err != nil {
				if os.IsNotExist(err) {
					m.log.Printf("ignoring non-existent file: %s", file)
					continue
				}

				m.log.Println(err)
				goto dontreplace
			}
		}

		m.aliasesLck.Lock()
		m.aliases = newAliases
		m.aliasesStamp = time.Now()
		m.aliasesLck.Unlock()
	dontreplace:
	}
}

func (m *Modifier) Close() error {
	m.stopReloader <- struct{}{}
	<-m.stopReloader
	return nil
}

func cleanReplacement(value string) (string, error) {
	// "a@b", just local-part, simply case-fold.
	if strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) {
		return strings.ToLower(value), nil
	}

	// whatever, just local-part, simply case-fold
	if !strings.Contains(value, `@`) {
		return strings.ToLower(value), nil
	}

	// whatever@whatever, complete address, apply case-folding, decode Punycode
	// and normalize for domain.
	return address.ForLookup(value)
}

func readFile(path string, out map[string]string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}

	scnr := bufio.NewScanner(f)
	lineCounter := 0

	parseErr := func(text string) error {
		return fmt.Errorf("%s:%d: %s", path, lineCounter, text)
	}

	for scnr.Scan() {
		lineCounter += 1
		if strings.HasPrefix(scnr.Text(), "#") {
			continue
		}

		text := strings.TrimSpace(scnr.Text())
		if text == "" {
			continue
		}

		parts := strings.SplitN(text, ":", 2)
		if len(parts) != 2 {
			return parseErr("invalid entry, missing colon")
		}

		fromAddr, err := cleanReplacement(strings.TrimSpace(parts[0]))
		if err != nil {
			return parseErr("malformed address: " + err.Error())
		}
		if len(fromAddr) == 0 {
			return parseErr("empty address before colon")
		}

		toAddrs := strings.Split(parts[1], ",")
		if len(toAddrs) > 1 {
			return parseErr("multiple addresses are not supported yet")
		}

		for i := range toAddrs {
			var err error
			toAddrs[i], err = cleanReplacement(strings.TrimSpace(toAddrs[i]))
			if err != nil {
				return parseErr("malformed address: " + err.Error())
			}
		}

		if fromAddr == "postmaster" && !strings.Contains(toAddrs[0], "@") {
			return parseErr("include replacement for <postmaster> as a full address to avoid ambiguity")
		}

		out[fromAddr] = toAddrs[0]
	}
	if err := scnr.Err(); err != nil {
		return err
	}

	return nil
}

type state struct {
	m *Modifier
}

func (m *Modifier) ModStateForMsg(ctx context.Context, msgMeta *module.MsgMetadata) (module.ModifierState, error) {
	return state{m: m}, nil
}

func (state) RewriteSender(ctx context.Context, from string) (string, error) {
	return from, nil
}

func (s state) RewriteRcpt(ctx context.Context, rcptTo string) (string, error) {
	// The existing map is never modified, instead it is replaced with a new
	// one if reload is performed.
	s.m.aliasesLck.RLock()
	aliases := s.m.aliases
	s.m.aliasesLck.RUnlock()

	normAddr, err := address.ForLookup(rcptTo)
	if err != nil {
		return rcptTo, fmt.Errorf("malformed address: %v", err)
	}

	replacement := aliases[normAddr]
	if replacement != "" {
		return replacement, nil
	}

	// Note: be careful to preserve original address case.

	// Okay, then attempt to do rewriting using
	// only mailbox.
	mbox, domain, err := address.Split(normAddr)
	if err != nil {
		// If we have malformed address here, something is really wrong, but let's
		// ignore it silently then anyway.
		return rcptTo, nil
	}

	// mbox is already normalized, since it is a part of address.ForLookup
	// result.
	replacement = aliases[mbox]
	if replacement != "" {
		if strings.Contains(replacement, "@") && !strings.HasPrefix(replacement, `"`) && !strings.HasSuffix(replacement, `"`) {
			return replacement, nil
		}
		return replacement + "@" + domain, nil
	}

	return rcptTo, nil
}

func (state) RewriteBody(ctx context.Context, hdr *textproto.Header, body buffer.Buffer) error {
	return nil
}

func (state) Close() error {
	return nil
}

func init() {
	module.Register(ModName, New)
}
