# provide ENV=dev to use .env.dev instead of .env
# and to work in the Pulumi dev stack
ENV_LOADED :=
ifeq ($(ENV), prod)
    ifneq (,$(wildcard ./.env))
        include .env
        export
				ENV_LOADED := Loaded config from .env
    endif
else
    ifneq (,$(wildcard ./.env.dev))
        include .env
        export
				ENV_LOADED := Loaded config from .env.dev
    endif
endif

.PHONY: help
.DEFAULT_GOAL := help

help: logo ## get a list of all the targets, and their short descriptions
	@# source for the incantation: https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | awk 'BEGIN {FS = ":.*?##"}; {printf "\033[1;38;5;214m%-12s\033[0m %s\n", $$1, $$2}'

it-all: logo document-store vector-index backend frontend ## runs all automated steps to get the application up and running

frontend: environment pulumi-config ## deploy the Discord bot server on AWS
	pulumi -C bot/ up --yes
	@tasks/pretty_log.sh "Allow 1-3 minutes for bot to start up"
	@tasks/pretty_log.sh "for startup debug logs, run sudo cat /var/log/cloud-init-output.log on the instance"
	@tasks/pretty_log.sh "for server logs, run tail -f /home/ec2-user/ask-fsdl/bot/log.out on the instance"

local-frontend: environment ## run the Discord bot server locally
	@tasks/pretty_log.sh "Assumes you've set up your bot in Discord, see https://discordpy.readthedocs.io/en/stable/discord.html"
	python bot/run.py --dev

backend: modal-auth ## deploy the Q&A backend on Modal
	@tasks/pretty_log.sh "Assumes you've set up the vector index, see vector-index"
	bash tasks/run_backend_modal.sh $(ENV)

cli-query: modal-auth ## run a query via a CLI interface
	@tasks/pretty_log.sh "Assumes you've set up the vector index"
	modal run app.py::stub.cli --query "${QUERY}"

vector-index: modal-auth secrets ## sets up a FAISS vector index to the application
	@tasks/pretty_log.sh "Assumes you've set up the document storage, see document-store"
	modal run app.py::stub.sync_vector_db_to_doc_db

document-store: environment secrets ## creates a MongoDB collection that contains the document corpus
	@tasks/pretty_log.sh "See docstore.py and the ETL notebook for details"
	modal run etl/shared.py::flush_doc_db # start from scratch
	modal run etl/videos.py --json-path data/videos.json
	modal run etl/markdown.py --json-path data/lectures-2022.json
	modal run etl/pdfs.py --json-path data/llm-papers.json

debugger: modal-auth ## starts a debugger running in our container but accessible via the terminal
	bash modal shell app.py

secrets: modal-auth  ## pushes secrets from .env to Modal
	@$(if $(value OPENAI_API_KEY),, \
		$(error OPENAI_API_KEY is not set. Please set it before running this target.))
	@$(if $(value MONGODB_URI),, \
		$(error MONGODB_URI is not set. Please set it before running this target.))
	@$(if $(value MONGODB_USER),, \
		$(error MONGODB_USER is not set. Please set it before running this target.))
	@$(if $(value MONGODB_PASSWORD),, \
		$(error MONGODB_PASSWORD is not set. Please set it before running this target.))
	bash tasks/send_secrets_to_modal.sh

modal-auth: environment ## confirms authentication with Modal, using secrets from `.env` file
	@tasks/pretty_log.sh "If you haven't gotten a Modal token yet, run make modal-token"
	@$(if $(value MODAL_TOKEN_ID),, \
		$(error MODAL_TOKEN_ID is not set. Please set it before running this target. See make modal-token.))
	@$(if $(value MODAL_TOKEN_SECRET),, \
		$(error MODAL_TOKEN_SECRET is not set. Please set it before running this target. See make modal-token.))
	@modal token set --token-id $(MODAL_TOKEN_ID) --token-secret $(MODAL_TOKEN_SECRET)

modal-token: environment ## creates token ID and secret for authentication with modal
	modal token new
	@tasks/pretty_log.sh "Copy the token info from the file mentioned above into .env"

pulumi-config:  ## adds secrets and config from env file to Pulumi
	@tasks/pretty_log.sh "For more on setting up a bot account in Discord, see https://discordpy.readthedocs.io/en/stable/discord.html"
	$(if $(filter dev, $(value ENV)),pulumi -C bot/ stack select dev, \
		pulumi -C bot/ stack select prod)
	@$(if $(value MODAL_USER_NAME),, \
		$(error MODAL_USER_NAME is not set. Please set it before running this target.))
	@$(if $(value DISCORD_AUTH),, \
		$(error DISCORD_AUTH is not set. Please set it before running this target.))
	@$(if $(value DISCORD_GUILD_ID),, \
		$(error DISCORD_GUILD_ID is not set. Please set it before running this target.))
	@pulumi -C bot/ config set MODAL_USER_NAME $(MODAL_USER_NAME)
	@pulumi -C bot/ config set --secret DISCORD_AUTH $(DISCORD_AUTH)
	@pulumi -C bot/ config set DISCORD_GUILD_ID $(DISCORD_GUILD_ID)
	@$(if $(value DISCORD_MAINTAINER_ID),pulumi -C bot/ config set --secret DISCORD_MAINTAINER_ID $(DISCORD_MAINTAINER_ID),)
	pulumi -C bot/ config

environment: ## installs required environment for deployment and corpus generation
	@if [ -z "$(ENV_LOADED)" ]; then \
			echo "Error: Configuration file not found" >&2; \
			exit 1; \
    else \
			tasks/pretty_log.sh "$(ENV_LOADED)"; \
	fi
	python -m pip install -qqq -r requirements.txt

dev-environment: environment  ## installs required environment for development
	python -m pip install -qqq -r requirements-dev.txt

logo:  ## prints the logo
	@cat logo.txt; echo "\n"
