# Common tasks. The scripts in scripts/ also run on their own.
.PHONY: build test package icon audit check hooks

build:     ## Build TypeThru.app
	scripts/build.sh
test:      ## Unit and fuzz tests; posts no input
	scripts/test.sh
package:   ## Build the download disk image
	scripts/package.sh
icon:      ## Redraw the app icon and README logos
	scripts/make-icon.sh
audit:     ## Security and repository checks
	scripts/audit.sh
check:     ## Everything that must pass before a push
	scripts/check.sh
hooks:     ## Run make check automatically before every git push
	git config core.hooksPath .githooks
