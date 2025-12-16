#!/usr/bin/env bash

# update-backend-fail.sh - Simulates a backend build failure
#
# This script simulates a backend update that fails during the build step.
# Used to test the automatic rollback mechanism.

echo "=========================================="
echo "Simulating backend update..."
echo "=========================================="

echo ""
echo "Step 1: Git pull (simulated)"
sleep 1
echo "  Already up to date."

echo ""
echo "Step 2: npm install (simulated)"
sleep 1
echo "  added 0 packages, removed 0 packages, and audited 1234 packages in 2s"
echo "  found 0 vulnerabilities"

echo ""
echo "Step 3: npm run build (simulated)"
sleep 1
echo "  > infinibay-backend@0.1.0 build"
echo "  > tsc"
echo ""

# Simulate TypeScript compilation error
echo "src/services/vm.ts(142,15): error TS2307: Cannot find module '@infinibay/types/missing' or its corresponding type declarations." >&2
echo "src/graphql/resolvers/vm.ts(89,23): error TS2339: Property 'invalidMethod' does not exist on type 'VMService'." >&2
echo "src/graphql/resolvers/vm.ts(156,7): error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'." >&2
echo "" >&2
echo "Found 3 errors in 2 files." >&2
echo "" >&2
echo "=========================================="
echo "ERROR: Build failed - TypeScript compilation error" >&2
echo "=========================================="

exit 1
