# Helm. The library builds and tests with spago; the targets here are for
# the hub's protocol and its conformance vectors (conformance/HELM-HUB.md).

VECTORS := conformance/vectors/helm-hub.json
MACHINES := conformance/machines
MACHINE_VECTORS := conformance/machine-vectors
GLASSBOX ?= ../../purescript-hylograph-libs/purescript-glassbox
GENERATE := node -e "import('./output/Hub.Generate/index.js').then(m => m.main())"

.PHONY: test vectors check-vectors conformance

test:
	spago test

# Regenerate the vector files. Runs the test first: vectors are never
# written from a reference that disagrees with its declared cases.
vectors: test
	$(GENERATE) > $(VECTORS).tmp
	mv $(VECTORS).tmp $(VECTORS)
	node hub/declaration.mjs write
	cd $(GLASSBOX) && spago run -p glassbox-cli --quiet -- lint $(CURDIR)/$(MACHINES)
	cd $(GLASSBOX) && spago run -p glassbox-cli --quiet -- vectors $(CURDIR)/$(MACHINES) $(CURDIR)/$(MACHINE_VECTORS)

# Fails if the committed vector file is not what the cases generate.
check-vectors: test
	$(GENERATE) | diff -u $(VECTORS) -
	node hub/declaration.mjs check

# The reference, then both ends of the wire, then the machine.
conformance: check-vectors
	node hub/conformance.mjs
	node hub/conformance-client.mjs
	node hub/conformance-machine.mjs
