PYTHON ?= python3
PACKCTL := PYTHONPATH=tools/packctl/src $(PYTHON) -m calla_tutor_pack
BLENDER_ADDON := build/blender/calla-tutor-blender-0.3.0.zip

.PHONY: test host-test pack-check pack-build pack-search blender-addon blender-test openclaw-test tools-test setup setup-server setup-macos

test: pack-check blender-test openclaw-test tools-test host-test
	PYTHONPATH=tools/packctl/src $(PYTHON) -m unittest discover -s tools/packctl/tests -v

pack-check:
	$(PACKCTL) validate packs/blender

pack-build:
	mkdir -p build/packs
	$(PACKCTL) compile packs/blender --output build/packs/blender.otpack

pack-search: pack-build
	$(PACKCTL) search build/packs/blender.otpack "$(QUERY)"

blender-addon:
	$(PYTHON) tools/package_blender_addon.py --output $(BLENDER_ADDON)

blender-test:
	$(PYTHON) -m unittest discover -s bridges/blender/tests -v

# The coordinate transform and the diagnosis sentences: both wrong silently.
host-test:
	cd apps/macos/TutorHost && swift test

openclaw-test:
	cd integrations/openclaw && npm test

tools-test:
	$(PYTHON) -m unittest discover -s tools/tests -v

setup: setup-server

setup-server:
	./scripts/setup-calla-server.sh --install --yes

setup-macos:
	./scripts/setup-macos.sh
