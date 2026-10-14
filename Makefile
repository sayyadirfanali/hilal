include config.mk

.PHONY: sync vendor build install deploy all status log backup

EXCLUDES = --include='hilal.env' --include='/azan/***' --exclude='.git/' --filter=':- .gitignore' --exclude='dist-newstyle/' --exclude='vendor/'

sync:
	rsync -avz --delete --delete-after $(EXCLUDES) -e ssh ./ $(REMOTE_HOST):$(REMOTE_DIR)/

vendor: sync
	ssh $(REMOTE_HOST) "cd $(REMOTE_DIR) && ./install_vendor.sh"

build: sync
	ssh $(REMOTE_HOST) "cd $(REMOTE_DIR) && . ~/.ghcup/env && ./build_css.sh && cabal build exe:hilal && install -m 755 \"\$$(cabal list-bin hilal)\" hilal"

install: build
	ssh $(REMOTE_HOST) "cd $(REMOTE_DIR) && sudo cp deploy/hilal.service /etc/systemd/system && sudo systemctl daemon-reload"

deploy: install
	ssh $(REMOTE_HOST) "sudo systemctl enable $(SERVICE_NAME) && sudo systemctl restart $(SERVICE_NAME)"

all: deploy

status:
	ssh $(REMOTE_HOST) "systemctl status $(SERVICE_NAME)"

log:
	ssh $(REMOTE_HOST) "journalctl -u $(SERVICE_NAME)"

backup:
	ssh $(REMOTE_HOST) 'cd $(REMOTE_DIR) && mkdir -p backups && sqlite3 hilal.db ".backup backups/hilal-$$(date +%Y%m%d-%H%M%S).db" && ls -1t backups/hilal-*.db | tail -n +11 | xargs -r rm --'
	mkdir -p backups
	rsync -av $(REMOTE_HOST):$(REMOTE_DIR)/backups/ backups/
	ls -1t backups/hilal-*.db | tail -n +31 | xargs -r rm --
