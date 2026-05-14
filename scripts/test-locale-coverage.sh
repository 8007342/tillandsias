#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-fr, spec:shell-prompt-localization-ja, spec:help-system-localization, spec:error-message-localization
# test-locale-coverage.sh — Verify locale bundle completeness and syntax
#
# Tests:
# 1. All L_* variables in en.sh are defined in {es,de,fr,ja}.sh
# 2. Bash syntax is valid for all locale files
# 3. All help-*.sh files have valid syntax

set -euo pipefail

LOCALES_DIR="./images/default/locales"
SCRIPTS_DIR="./scripts"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         Locale Bundle Coverage & Syntax Tests             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Test 1: Verify all L_* variables are present in each locale
echo "TEST 1: Variable coverage (all L_* vars in en.sh present in locale bundles)"
echo "─────────────────────────────────────────────────────────────────────────"

if [ ! -d "$LOCALES_DIR" ]; then
    echo "ERROR: Locales directory not found: $LOCALES_DIR"
    exit 1
fi

# Extract all L_* variable names from English
en_vars=$(grep "^L_" "$LOCALES_DIR/en.sh" | cut -d'=' -f1 | sort)
en_count=$(echo "$en_vars" | wc -l)

echo "English: $en_count variables"

all_pass=true
for locale in es de fr ja; do
    locale_file="$LOCALES_DIR/${locale}.sh"
    if [ ! -f "$locale_file" ]; then
        echo "✗ FAIL: Locale file not found: $locale_file"
        all_pass=false
        continue
    fi

    locale_vars=$(grep "^L_" "$locale_file" | cut -d'=' -f1 | sort)
    locale_count=$(echo "$locale_vars" | wc -l)

    missing=$(comm -23 <(echo "$en_vars") <(echo "$locale_vars") || true)
    if [ -z "$missing" ]; then
        echo "✓ PASS: ${locale}.sh ($locale_count/$en_count variables)"
    else
        echo "✗ FAIL: ${locale}.sh missing variables:"
        echo "$missing" | sed 's/^/        /'
        all_pass=false
    fi
done

echo ""

# Test 2: Bash syntax validation
echo "TEST 2: Bash syntax validation"
echo "─────────────────────────────────────────────────────────────────────────"

for locale in en es de fr ja; do
    locale_file="$LOCALES_DIR/${locale}.sh"
    if bash -n "$locale_file" 2>/dev/null; then
        echo "✓ PASS: ${locale}.sh syntax valid"
    else
        echo "✗ FAIL: ${locale}.sh has syntax errors"
        bash -n "$locale_file" 2>&1 | sed 's/^/        /'
        all_pass=false
    fi
done

echo ""

# Test 3: Help script syntax validation
echo "TEST 3: Help script syntax validation"
echo "─────────────────────────────────────────────────────────────────────────"

if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "WARNING: Scripts directory not found: $SCRIPTS_DIR (skipping help tests)"
else
    for help_script in help.sh help-es.sh help-fr.sh help-de.sh help-ja.sh; do
        script_file="$SCRIPTS_DIR/$help_script"
        if [ ! -f "$script_file" ]; then
            echo "✗ FAIL: Script not found: $script_file"
            all_pass=false
        elif bash -n "$script_file" 2>/dev/null; then
            echo "✓ PASS: $help_script syntax valid"
        else
            echo "✗ FAIL: $help_script has syntax errors"
            bash -n "$script_file" 2>&1 | sed 's/^/        /'
            all_pass=false
        fi
    done
fi

echo ""

# Summary
if [ "$all_pass" = true ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║              ALL TESTS PASSED ✓                           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║              SOME TESTS FAILED ✗                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    exit 1
fi
