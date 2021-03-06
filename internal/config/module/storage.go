package modconfig

import (
	"github.com/foxcpp/maddy/internal/config"
	"github.com/foxcpp/maddy/internal/module"
)

func StorageDirective(m *config.Map, node *config.Node) (interface{}, error) {
	var backend module.Storage
	if err := ModuleFromNode(node.Args, node, m.Globals, &backend); err != nil {
		return nil, err
	}
	return backend, nil
}
