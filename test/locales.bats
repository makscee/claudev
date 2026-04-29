#!/usr/bin/env bats

@test "en.sh and ru.sh exist" {
  [ -f "$BATS_TEST_DIRNAME/../locales/en.sh" ]
  [ -f "$BATS_TEST_DIRNAME/../locales/ru.sh" ]
}

@test "en.sh defines all required keys" {
  . "$BATS_TEST_DIRNAME/../locales/en.sh"
  [ -n "${L_CHOOSE_LANG:-}" ]
  [ -n "${L_HEADER_FMT:-}" ]
  [ -n "${L_UPDATE_AVAILABLE:-}" ]
  [ -n "${L_UPDATE_INSTALL_PROMPT:-}" ]
  [ -n "${L_CLAUDE_NOT_FOUND:-}" ]
  [ -n "${L_CLAUDE_INSTALL_PROMPT:-}" ]
  [ -n "${L_CLAUDE_INSTALL_FAILED:-}" ]
  [ -n "${L_PASTE_CODE:-}" ]
  [ -n "${L_INVALID_CODE:-}" ]
  [ -n "${L_TOO_MANY_ATTEMPTS:-}" ]
  [ -n "${L_NETWORK_ERROR:-}" ]
  [ -n "${L_SESSION_REVOKED:-}" ]
  [ -n "${L_POOL_EMPTY:-}" ]
  [ -n "${L_POOL_BAD_KEY:-}" ]
}

@test "ru.sh defines the same keys as en.sh" {
  en_keys=$(grep -E '^L_[A-Z_]+=' "$BATS_TEST_DIRNAME/../locales/en.sh" | cut -d= -f1 | sort)
  ru_keys=$(grep -E '^L_[A-Z_]+=' "$BATS_TEST_DIRNAME/../locales/ru.sh" | cut -d= -f1 | sort)
  [ "$en_keys" = "$ru_keys" ]
}
