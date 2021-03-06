maddy-targets(5) "maddy mail server" "maddy reference documentation"

; TITLE Delivery targets

This man page describes modules that can used with 'deliver_to' directive
of SMTP endpoint module.

# SQL module (sql)

SQL module described in *maddy-storage*(5) can also be used as a delivery
target.

# Queue module (queue)

Queue module buffers messages on disk and retries delivery multiple times to
another target to ensure reliable delivery.

```
queue {
    target remote
    location ...
    max_parallelism 16
    max_tries 4
	bounce {
	    destination example.org {
	        deliver_to &local_mailboxes
	    }
	    default_destination {
	        reject
	    }
	}

    autogenerated_msg_domain example.org
    debug no
}
```

## Arguments

First argument specifies directory to use for storage.
Relative paths are relative to the StateDirectory.

## Configuration directives

*Syntax*: target _block_name_ ++
*Default*: not specified

REQUIRED.

Delivery target to use for final delivery.

*Syntax*: location _directory_ ++
*Default*: StateDirectory/configuration_block_name

File system directory to use to store queued messages.
Relative paths are relative to the StateDirectory.

*Syntax*: max_parallelism _integer_ ++
*Default*: 16

Start up to _integer_ goroutines for message processing. Basically, this option
limits amount of messages tried to be delivered concurrently.

*Syntax*: max_tries _integer_ ++
*Default*: 4

Attempt delivery up to _integer_ times. Note that no more attempts will be done
is permanent error occured during previous attempt.

*Syntax*: bounce { ... } ++
*Default*: not specified

This configuration contains pipeline configuration to be used for generated DSN
(Delivery Status Notifiaction) messages.

If this is block is not present in configuration, DSNs will not be generated.
Note, however, this is not what you want most of the time.

*Syntax*: autogenerated_msg_domain _domain_ ++
*Default*: global directive value

Domain to use in sender address for DSNs. Should be specified too if 'bounce'
block is specified.

*Syntax*: debug _boolean_ ++
*Default*: no

Enable verbose logging.

# Remote MX module (remote)

Module that implements message delivery to remote MTAs discovered via DNS MX
records. You probably want to use it with queue module for reliability.

```
remote {
    hostname mx.example.org
    debug no
}
```

If a message check marks a message as 'quarantined', remote module
will refuse to deliver it.

## Configuration directives

*Syntax*: hostname _domain_ ++
*Default*: global directive value

Hostname to use client greeting (EHLO/HELO command). Some servers require it to
be FQDN, SPF-capable servers check whether it corresponds to the server IP
address, so it is better to set it to a domain that resolves to the server IP.

*Syntax*: min_mx_level none|mtasts|dnssec ++
*Default*: none

Minimal MX records security level to require before using remote server for
delivery. See [Security levels](../../seclevels) page for details.

*Syntax*: min_tls_level none|encrypted|authenticated
*Default*: none

Minimal MX records security level to require before using remote server for
delivery. See [Security levels](../../seclevels) page for details.

*Syntax*: debug _boolean_ ++
*Default*: global directive value

Enable verbose logging.

## Security policies

'remote' module implements a number of of schemes and protocols necessary to
ensure security of message delivery. Most of these schemes are concerned with
authentication of recipient server and TLS enforcement.

Each of the specified mechanisms can be disabled by specifying 'mech off' where
'mech' is the name of corresponding configuration block (e.g. 'dane off' to
disable DANE). However, it is not recommended to do so as it degrades delivery
security considerably.

## Security policies: MTA-STS

Checks MTA-STS policy of the recipient domain. Provides proper authentication
and TLS enforcement for delivery, but partially vulnerable to persistent active
attacks.

Sets MX level to "mtasts" if the used MX matches MTA-STS policy even if it is
not set to "enforce" mode.

```
mtasts {
	cache fs
	fs_dir StateDirectory/mtasts_cache
}
```

*Syntax*: cache fs|ram ++
*Default*: fs

Storage to use for MTA-STS cache. 'fs' is to use a filesystem directory, 'ram'
to store the cache in memory.

It is recommended to use 'fs' since that will not discard the cache (and thus
cause MTA-STS security to disappear) on server restart. However, using the RAM
cache can make sense for high-load configurations with good uptime.

*Syntax*: fs_dir _directory_ ++
*Default*: StateDirectory/mtasts_cache

Filesystem directory to use for policies caching if 'cache' is set to 'fs'.

## Security policies: STARTTLS Everywhere

Apply rules from the STARTTLS Everywhere list or from any other similarly
structured list.

See https://starttls-everywhere.org for details.

```
sts_preload {
	source eff
	early_adopter yes
}
```

*Syntax*: source eff | file://path | https://path ++
*Default*: eff

Source to download the list from. 'eff' is the alias to use the STARTTLS
Everywhere list maintained by EFF. In addition to that, 'eff' alias enables
verification of PGP signature using hardcoded PGP key.

When the argument starts with file://, it should point to the local FS file
with the list.
When HTTPS URI is used, the list is downloaded from that location.

In all cases, the list is checked for updates when it is about to expiry.

*Syntax*: enforce_testing _boolean_ ++
*Default*: yes

Interpret 'testing' records as enforced ones. Using this makes list actually
useful for security at the risk of deliverability problems if record becomes
out-of-date and host does not publish an MTA-STS policy .

## Security policies: DNSSEC

Checks whether MX records are signed. Sets MX level to "dnssec" is they are.

maddy does not validate DNSSEC signatures on its own. Instead it reslies on
the upstream resolver to do so by causing lookup to fail when verification
fails and setting the AD flag for signed and verfified zones. As a safety
measure, if the resolver is not 127.0.0.1 or ::1, the AD flag is ignored.

DNSSEC is currently not supported on Windows and other platforms that do not
have the /etc/resolv.conf file in the standard format.

```
dnssec { }
```

## Security policies: DANE

Checks TLSA records for the recipient MX. Provides downgrade-resistant TLS
enforcement.

Sets TLS level to "authenticated" if a valid and matching TLSA record uses
DANE-EE or DANE-TA usage type.

See above for notes on DNSSEC. DNSSEC support is required for DANE to work.

```
dane { }
```

## Security policies: Local policy

Checks effective TLS and MX levels (as set by other policies) against local
configuration.

```
local_policy {
	min_tls_level none
	min_mx_level none
}
```

Using 'local_policy off' is equivalent to setting both directives to 'none'.

*Syntax*: min_tls_level none|encrypted|authenticated ++
*Default*: none

Set the minimal TLS security level required for all outbound messages.

See [Security levels](../../seclevels) page for details.

*Syntax*: min_mx_level: none|mtasts|dnssec ++
*Default*: none

Set the minimal MX security level required for all outbound messages.

See [Security levels](../../seclevels) page for details.

# SMTP transparent forwarding module (smtp_downstream)

Module that implements transparent forwarding of messages over SMTP.

Use in pipeline configuration:
```
deliver_to smtp_downstream tcp://127.0.0.1:5353
# or
deliver_to smtp_downstream tcp://127.0.0.1:5353 {
  # Other settings, see below.
}
```

```
smtp_downstream {
    debug no
    tls_client {
        ...
    }
    attempt_starttls yes
    require_yes no
    auth off
    target tcp://127.0.0.1:2525
}
```

Endpoint addresses use format described in *maddy-config*(5).

## Configuration directives

*Syntax*: debug _boolean_ ++
*Default*: global directive value

Enable verbose logging.

*Syntax*: tls_client { ... } ++
*Default*: not specified

Advanced TLS client configuration options. See *maddy-tls*(5) for details.

*Syntax*: attempt_starttls _boolean_ ++
*Default*: yes

Attempt to use STARTTLS if it is supported by the remote server.
If TLS handshake fails, connection will be retried without STARTTLS use
unless 'require_tls' is also specified.

*Syntax*: require_tls _boolean_ ++
*Default*: no

Refuse to pass messages over plain-text connections.

*Syntax*: ++
    auth off ++
    plain _username_ _password_ ++
    forward ++
    external ++
*Default*: off

Specify the way to authenticate to the remote server.
Valid values:

- off

	No authentication.

- plain

	Authenticate using specified username-password pair.
	*Don't use* this without enforced TLS ('require_tls').

- forward

	Forward credentials specified by the client.
	*Don't use* this without enforced TLS ('require_tls').

- external

	Request "external" SASL authentication. This is usually used for
	authentication using TLS client certificates. See *maddy-tls*(5)
	for how to specify the client certificate.

*Syntax*: target _endpoints..._ ++
*Default:* not specified

REQUIRED.

List of remote server addresses to use. See Address definitions in
*maddy-config*(5) for syntax to use.  Basically, it is 'tcp://ADDRESS:PORT'
for plain SMTP and 'tls://ADDRESS:PORT' for SMTPS (aka SMTP with Implicit
TLS).

Multiple addresses can be specified, they will be tried in order until connection to
one succeeds (including TLS handshake if TLS is required).
