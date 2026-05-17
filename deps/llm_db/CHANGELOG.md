# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project uses [Calendar Versioning](https://calver.org/) with the format `YYYY.MM.PATCH`.

<!-- changelog -->

## [2026.4.8](https://github.com/agentjido/llm_db/compare/v2026.4.8...2026.4.8) (2026-04-29)




### Features:

* deprecate deepseek-chat/reasoner, add v4-flash and v4-pro (#181) by Kasun Vithanage

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* harden metadata publish validation by github-actions[bot]

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.7](https://github.com/agentjido/llm_db/compare/v2026.4.7...2026.4.7) (2026-04-27)




### Features:

* deprecate deepseek-chat/reasoner, add v4-flash and v4-pro (#181) by Kasun Vithanage

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* harden metadata publish validation by github-actions[bot]

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.6](https://github.com/agentjido/llm_db/compare/v2026.4.6...2026.4.6) (2026-04-23)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* harden metadata publish validation by github-actions[bot]

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.5](https://github.com/agentjido/llm_db/compare/v2026.4.5...2026.4.5) (2026-04-21)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* harden metadata publish validation by github-actions[bot]

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.4](https://github.com/agentjido/llm_db/compare/v2026.4.4...2026.4.4) (2026-04-19)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.3](https://github.com/agentjido/llm_db/compare/v2026.4.3...2026.4.3) (2026-04-16)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.2](https://github.com/agentjido/llm_db/compare/v2026.4.2...2026.4.2) (2026-04-14)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Support model specific base_url (#86) by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* preserve sparse overlay intent across merges by mikehostetler

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.1](https://github.com/agentjido/llm_db/compare/v2026.4.1...2026.4.1) (2026-04-08)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add llmfit sidecar enrichment for hf metadata by mikehostetler

* cut over metadata history to snapshot store by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* add Azure AI Foundry source module by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* update model metadata (3 new, 42 updated) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* exclude chatgpt-4o-latest from OpenAI catalog (#172) by Jonathan Schweder

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* satisfy dialyzer for snapshot tasks by mikehostetler

* clarify initial history seed failures by mikehostetler

* align azure provider metadata by ycastorium

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* sync model history for current metadata by github-actions[bot]

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.4.0](https://github.com/agentjido/llm_db/compare/v2026.4.0...2026.4.0) (2026-04-01)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add llmfit sidecar enrichment for hf metadata by mikehostetler

* cut over metadata history to snapshot store by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* add Azure AI Foundry source module by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* update model metadata (3 new, 42 updated) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* providers: adding snapshop.json by Julien

* providers: Add novita_ai and scaleway base_url, also add embedding models in novita_ai by Julien

* ci: keep snapshot automation reproducible by github-actions[bot]

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* satisfy dialyzer for snapshot tasks by mikehostetler

* clarify initial history seed failures by mikehostetler

* align azure provider metadata by ycastorium

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* sync model history for current metadata by github-actions[bot]

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.3.3](https://github.com/agentjido/llm_db/compare/v2026.3.3...2026.3.3) (2026-03-23)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add llmfit sidecar enrichment for hf metadata by mikehostetler

* cut over metadata history to snapshot store by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* add Azure AI Foundry source module by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* update model metadata (3 new, 42 updated) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* align zenmux caching and refresh snapshot by mikehostetler

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* satisfy dialyzer for snapshot tasks by mikehostetler

* clarify initial history seed failures by mikehostetler

* align azure provider metadata by ycastorium

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* sync model history for current metadata by github-actions[bot]

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.3.2](https://github.com/agentjido/llm_db/compare/v2026.3.2...2026.3.2) (2026-03-14)




### Features:

* cut over metadata history to snapshot store (#158) by mikehostetler

* add llmfit sidecar enrichment for hf metadata by mikehostetler

* cut over metadata history to snapshot store by mikehostetler

* add Azure AI Foundry source module (#146) by ycastorium

* add Azure AI Foundry source module by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* update model metadata (3 new, 42 updated) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* pass token to release snapshot fetch by mikehostetler

* allow stale history in CI checks by mikehostetler

* align local and published history metadata by mikehostetler

* use tar for history bundle archives by mikehostetler

* use unique immutable release tags by mikehostetler

* support immutable GitHub releases for snapshots by mikehostetler

* accept gh release stdout when publishing by mikehostetler

* avoid struct access in llmfit enrichment by mikehostetler

* satisfy dialyzer for snapshot tasks by mikehostetler

* clarify initial history seed failures by mikehostetler

* align azure provider metadata by ycastorium

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* sync model history for current metadata by github-actions[bot]

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.3.1](https://github.com/agentjido/llm_db/compare/v2026.3.1...2026.3.1) (2026-03-10)




### Features:

* add Azure AI Foundry source module (#146) by ycastorium

* add Azure AI Foundry source module by ycastorium

* update model metadata (3 new, 42 updated) (#156) by github-actions[bot]

* update model metadata (3 new, 42 updated) by github-actions[bot]

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* align azure provider metadata by ycastorium

* remove unreachable history recovery clauses by mikehostetler

* simplify metadata refresh and history recovery by mikehostetler

* sync model history for current metadata by github-actions[bot]

* align metadata history sync with committed metadata by mikehostetler

* sync model history for current metadata (#150) by mikehostetler

* update model metadata for 5 provider(s) (#141) by github-actions[bot]

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.3.0](https://github.com/agentjido/llm_db/compare/v2026.3.0...2026.3.0) (2026-03-03)




### Features:

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 9 provider(s) (#134) by github-actions[bot]

* include OpenRouter in mix llm_db.pull sources (#139) by mikehostetler

* pull: wire openrouter source into llm_db.pull by mikehostetler

* ci: tolerate squash-merged metadata history drift by mikehostetler

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.9](https://github.com/agentjido/llm_db/compare/v2026.2.9...2026.2.9) (2026-02-27)




### Features:

* add spec-aware history sync API and runtime reader (#129) by mikehostetler

* history: add git backfill task and initial history dataset by mikehostetler

* history: add spec-aware history sync and runtime reader by mikehostetler

* Use canonical costs for dated models (#132) by ycastorium

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 9 provider(s) (#133) by github-actions[bot]

* history: resolve dialyzer warnings in sync tasks by mikehostetler

* history: stabilize CI history checks and refresh artifacts by mikehostetler

* history: harden cache init and sync bootstrap by mikehostetler

* history: serialize first-load index refresh by mikehostetler

* spec: use amazon_bedrock provider and add missing inference profile prefixes (#130) by stevehodgkiss

* resolve Bedrock inference profile prefixes in Store.model/2 by stevehodgkiss

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.8](https://github.com/agentjido/llm_db/compare/v2026.2.8...2026.2.8) (2026-02-20)




### Features:

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 25 provider(s) (#126) by github-actions[bot]

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.7](https://github.com/agentjido/llm_db/compare/v2026.2.7...2026.2.7) (2026-02-17)




### Features:

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 19 provider(s) (#125) by github-actions[bot]

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.6](https://github.com/agentjido/llm_db/compare/v2026.2.6...2026.2.6) (2026-02-16)




### Features:

* build: add --check flag and guardrails to prevent editing generated files (#120) by mikehostetler

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 30 provider(s) (#122) by github-actions[bot]

* clean up llm_db install task copy by mikehostetler

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.5](https://github.com/agentjido/llm_db/compare/v2026.2.5...2026.2.5) (2026-02-11)




### Features:

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 18 provider(s) (#117) by github-actions[bot]

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.4](https://github.com/agentjido/llm_db/compare/v2026.2.4...2026.2.4) (2026-02-09)




### Features:

* add flexible lifecycle extension for models (#110) by mikehostetler

* add flexible lifecycle extension for models by mikehostetler

* add Groq speech-to-text models (whisper-large-v3, whisper-large-v3-turbo) (#114) by James Tippett

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 87 provider(s) (#115) by github-actions[bot]

* harden lifecycle API with boolean fallback, retires_at semantics, and non-map guard by mikehostetler

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.3](https://github.com/agentjido/llm_db/compare/v2026.2.3...2026.2.3) (2026-02-05)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 20 provider(s) (#113) by github-actions[bot]

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.2](https://github.com/agentjido/llm_db/compare/v2026.2.2...2026.2.2) (2026-02-02)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* add grok-imagine-image pricing via local TOML override (#106) by Victor

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.1](https://github.com/agentjido/llm_db/compare/v2026.2.1...2026.2.1) (2026-02-01)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 3 provider(s) (#104) by github-actions[bot]

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.2.0](https://github.com/agentjido/llm_db/compare/v2026.2.0...2026.2.0) (2026-02-01)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* proper metadata for grok-imagine-image (#103) by Victor

* add xai image model metadata by Victor

* correct grok-imagine-image pricing by Victor

* add grok-imagine-image input image pricing by Victor

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.1.5](https://github.com/agentjido/llm_db/compare/v2026.1.5...2026.1.5) (2026-01-30)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 17 provider(s) (#102) by github-actions[bot]

* add explicit wire.protocol metadata for OpenAI models (#101) by Victor

* explicitly define metadata for modern OpenAI models, fix #100 by Victor

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.1.4](https://github.com/agentjido/llm_db/compare/v2026.1.4...2026.1.4) (2026-01-28)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* test environment (#98) by Victor

* clear config before each test by Victor

* allow provider names to start with a digit (302ai is a legitimate provider) by Victor

* update model metadata for 3 provider(s) (#97) by github-actions[bot]

* add pricing metadata, close #93 (#96) by Victor

* add pricing information for gemini-3-pro-image-preview by Victor

* add pricing for gpt-3.5-turbo-16k by Victor

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.1.3](https://github.com/agentjido/llm_db/compare/v2026.1.3...2026.1.3) (2026-01-28)




### Features:

* Add pricing and billing support for tool usage (#92) by Victor

* Initial billing support for tool usage by Victor

* add metadata and pricing for OpenAI image generation models by Victor

* add Pricing and Billing guide by Victor

* Support model specific base_url (#86) by meanderingstream

* add model specific base_url configuration by meanderingstream

* Add documentation for model base_url by meanderingstream

* Add Cohere models to Bedrock (#90) by ycastorium

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 84 provider(s) (#94) by github-actions[bot]

* remove cost.image to pricing component conversion by Victor

* correct Google cache and embedding pricing by Victor

* handle string id_key for atom maps by Victor

* clear :filter env in test setup to prevent pollution by Victor

* Elixir 1.20.0-rc.1 warnings by Victor

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.1.2](https://github.com/agentjido/llm_db/compare/v2026.1.2...2026.1.2) (2026-01-26)




### Features:

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 20 provider(s) (#85) by github-actions[bot]

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.1.1](https://github.com/agentjido/llm_db/compare/v2026.1.1...2026.1.1) (2026-01-19)




### Features:

* metadata: add Zenmux API key to build metadata workflow by mikehostetler

* providers: add support for Zenmux provider (#75) by youfun

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 67 provider(s) (#84) by github-actions[bot]

* add metadata for grok-4-0709 and grok-4-1-fast-reasoning (#83) by Victor

* Add mising metadata for grok-4-0709 and grok-4-1-fast-reasoning by Victor

* update model metadata for 8 provider(s) (#79) by github-actions[bot]

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2026.1.0](https://github.com/agentjido/llm_db/compare/v2026.1.0...2026.1.0) (2026-01-05)




### Features:

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 13 provider(s) (#72) by github-actions[bot]

* keep OpenRouter models under :openrouter with full IDs (#70) by mikehostetler

* update model metadata for 17 provider(s) (#71) by github-actions[bot]

* update model metadata for 15 provider(s) (#65) by github-actions[bot]

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2025.12.4](https://github.com/agentjido/llm_db/compare/v2025.12.4...2025.12.4) (2025-12-26)




### Features:

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* Don't load env files if .env is a directory (#64) by sezaru

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2025.12.3](https://github.com/agentjido/llm_db/compare/v2025.12.3...2025.12.3) (2025-12-22)




### Features:

* add wire.protocol and constraints metadata fields (#59) by mikehostetler

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 12 provider(s) (#61) by github-actions[bot]

* inherit custom config from app env in Runtime.compile/1 (#58) by Nils

* update model metadata for 51 provider(s) (#57) by github-actions[bot]

* round cost values to six decimal places in OpenRouter by mikehostetler

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

### Improvements:

* Add gemini-2.5-flash-image and gemini-2.5-flash-lite (#60) by Victor

## [2025.12.2](https://github.com/agentjido/llm_db/compare/v2025.12.2...2025.12.2) (2025-12-17)




### Features:

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* update model metadata for 5 provider(s) (#55) by github-actions[bot]

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

## [2025.12.1](https://github.com/agentjido/llm_db/compare/v2025.12.1...2025.12.1) (2025-12-17)




### Features:

* add hex_dry_run option and version bump commit to release workflow by mikehostetler

* sort JSON keys for deterministic output (#51) by mikehostetler

* sort JSON keys for deterministic output by mikehostetler

* add git_hooks integration for code quality enforcement (#42) by mikehostetler

### Bug Fixes:

* add fetch-tags option and debug output to release workflow by mikehostetler

* fetch tags explicitly in release workflow by mikehostetler

* update model metadata for 69 provider(s) (#50) by github-actions[bot]

* disable git hooks in CI workflow by mikehostetler

* use commit-message instead of invalid commit-message-path by mikehostetler

* restrict llm_db.build and llm_db.pull tasks to llm_db project only (#49) by mikehostetler

## [2025.12.0](https://github.com/agentjido/llm_db/compare/v2025.11.18...v2025.12.0) - 2025-12-17

### Changed

- Updated model data from upstream sources (includes Gemini 3 Pro Preview)
- JSON snapshot keys are now sorted for deterministic output (#51)
- Added git_hooks integration for code quality enforcement (#42)
- Restricted `llm_db.build` and `llm_db.pull` tasks to llm_db project only (#49)

## [2025.11.18-preview] - 2025-11-18

### Added

- New models available: GPT 5.1 (OpenAI) and Gemini 3 (Google)
- Provider alias system to enable single implementation handling models from multiple LLMDB providers
  - New `alias_of` field in Provider struct points aliased provider to primary implementation
  - `LLMDB.Store.models/1` now searches aliased providers when looking up by provider ID
  - `LLMDB.Store.model/2` normalizes provider field back to requested provider for aliased models
  - First implementation: `google_vertex_anthropic` aliases to `google_vertex` for Claude models on Vertex AI
- `provider_model_id` field for AWS Bedrock inference profile models that require API-specific identifiers
  - Enables models to use canonical IDs (e.g., `anthropic.claude-haiku-4-5-20251001-v1:0`) while making API calls with inference profile prefixes (e.g., `us.anthropic.claude-haiku-4-5-20251001-v1:0`)
  - Addresses AWS requirement: "Invocation of model ID [...] with on-demand throughput isn't supported. Retry your request with the ID or ARN of an inference profile"
  - Applied to: Claude Haiku 4.5, Claude Sonnet 4.5, Claude Opus 4.1, Llama 3.3 70B, Llama 3.2 3B
- `.env.example` file for environment variable configuration

### Changed

- Snapshot JSON is now pretty-printed for easier diffing
- Updated Zoi dependency to version 0.10.7
- Updated Dotenvy dependency to version 1.1
- ModelsDev transformer now auto-sets `streaming.tool_calls: true` when `tool_call: true`
  - Reflects reality: 99%+ of tool-capable models support streaming tool calls
  - Eliminates need for model-specific TOML overrides for common case
  - Rare exceptions can override with `streaming.tool_calls: false` in TOML

### Fixed

- Claude Opus 4.1: Changed `provider_model_id` from `global.` to `us.` prefix - Opus 4.1 is only available with `us.` inference profile on AWS Bedrock, not `global.` like Haiku and Sonnet
- Claude Haiku 4.5 and Sonnet 4.5: Override `tools.strict=false` to disable object generation hack - waiting for native Anthropic JSON support instead
- Model spec parsing now handles ambiguous formats (specs with both `:` and `@` separators) by attempting provider validation to determine the correct format
- Removed overly strict character validation that rejected `@` in model IDs when using colon format and `:` in model IDs when using @ format

## [2025.11.14-preview] - 2025-11-14

### Added

- `LLMDB.Model.format_spec/1` function for converting model struct to provider:model string format
- Zai Coder provider and GLM models support
- Enhanced cost schema with granular multimodal and reasoning pricing fields:
  - `reasoning`: Cost per 1M reasoning/thinking tokens for models like o1, Grok-4
  - `input_audio`/`output_audio`: Separate audio input/output costs (e.g., Gemini 2.5 Flash, Qwen-Omni)
  - `input_video`/`output_video`: Video input/output cost support for future models
- ModelsDev source transformer now captures all cost fields from models.dev data
- OpenRouter source transformer maps `internal_reasoning` field to `reasoning` cost

### Changed

- Updated Zoi dependency to version 0.10.6
- Refactored loader to use dynamic snapshot retrieval
- Disabled schema validation in snapshot.json and TOML source files

### Fixed

- Cleaned up code quality issues
- Fixed application startup crash (`ArgumentError: not an already existing atom`) caused by race condition between build task and snapshot loading
- Fixed flaky tests in `LLMDB.EngineOverrideTest` by ensuring test isolation from global config
