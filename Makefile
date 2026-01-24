# zig-json Makefile
# Developer convenience targets for building, testing, and development

.PHONY: all build test test-unit test-vectors test-conformance test-all \
        fmt fmt-check check dev clean docs \
        test-release-safe test-release-fast test-release-small test-all-optimizations \
        ci install-deps help

# Default target
all: build test-unit test-vectors test-conformance

# ============================================================
# Build Targets
# ============================================================

build:
	zig build

# ============================================================
# Test Targets
# ============================================================

test: test-unit test-vectors

test-unit:
	zig build test --summary all

test-vectors:
	zig build test-vectors --summary all

test-conformance:
	zig build test-conformance --summary all

test-all: test-unit test-vectors test-conformance

# ============================================================
# Optimization Variant Testing
# ============================================================

test-release-safe:
	zig build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	zig build test -Doptimize=ReleaseFast --summary all

test-release-small:
	zig build test -Doptimize=ReleaseSmall --summary all

test-all-optimizations: test-unit test-release-safe test-release-fast test-release-small

# ============================================================
# Development Targets
# ============================================================

fmt:
	zig fmt src/ tests/ build.zig

fmt-check:
	zig fmt --check src/ tests/ build.zig

check:
	zig build --summary all 2>&1 || true

# Quick development cycle: format, check, and run unit tests
dev: fmt check test-unit

# ============================================================
# Documentation
# ============================================================

docs:
	zig build docs

# ============================================================
# CI/CD
# ============================================================

ci: clean build test-all fmt-check

# ============================================================
# Cleanup
# ============================================================

clean:
	rm -rf zig-out/ .zig-cache/

# ============================================================
# Cross-Compilation Targets
# ============================================================

cross-linux-arm:
	zig build -Dtarget=arm-linux-gnueabihf

cross-linux-arm64:
	zig build -Dtarget=aarch64-linux-gnu

cross-linux-riscv64:
	zig build -Dtarget=riscv64-linux-gnu

cross-windows-x86_64:
	zig build -Dtarget=x86_64-windows-gnu

cross-windows-arm64:
	zig build -Dtarget=aarch64-windows-msvc

cross-macos-x86_64:
	zig build -Dtarget=x86_64-macos

cross-macos-arm64:
	zig build -Dtarget=aarch64-macos

cross-freebsd:
	zig build -Dtarget=x86_64-freebsd

cross-netbsd:
	zig build -Dtarget=x86_64-netbsd

cross-all: cross-linux-arm cross-linux-arm64 cross-linux-riscv64 \
           cross-windows-x86_64 cross-windows-arm64 \
           cross-macos-x86_64 cross-macos-arm64 \
           cross-freebsd cross-netbsd

# ============================================================
# Help
# ============================================================

help:
	@echo "zig-json Makefile targets:"
	@echo ""
	@echo "Build:"
	@echo "  all                    - Build and run all tests (default)"
	@echo "  build                  - Build the library"
	@echo ""
	@echo "Testing:"
	@echo "  test                   - Run unit tests and test vectors"
	@echo "  test-unit              - Run unit tests only"
	@echo "  test-vectors           - Run RFC/spec test vectors"
	@echo "  test-conformance       - Run conformance tests"
	@echo "  test-all               - Run all test suites"
	@echo ""
	@echo "Optimization Testing:"
	@echo "  test-release-safe      - Test with ReleaseSafe optimization"
	@echo "  test-release-fast      - Test with ReleaseFast optimization"
	@echo "  test-release-small     - Test with ReleaseSmall optimization"
	@echo "  test-all-optimizations - Test all optimization levels"
	@echo ""
	@echo "Development:"
	@echo "  fmt                    - Format all source files"
	@echo "  fmt-check              - Check formatting without changes"
	@echo "  check                  - Syntax check without full compilation"
	@echo "  dev                    - Quick dev cycle (fmt + check + test-unit)"
	@echo "  docs                   - Generate documentation"
	@echo ""
	@echo "Cross-Compilation:"
	@echo "  cross-linux-arm        - Build for ARM 32-bit Linux"
	@echo "  cross-linux-arm64      - Build for ARM64 Linux"
	@echo "  cross-linux-riscv64    - Build for RISC-V 64-bit Linux"
	@echo "  cross-windows-x86_64   - Build for Windows x86_64"
	@echo "  cross-windows-arm64    - Build for Windows ARM64"
	@echo "  cross-macos-x86_64     - Build for macOS Intel"
	@echo "  cross-macos-arm64      - Build for macOS Apple Silicon"
	@echo "  cross-freebsd          - Build for FreeBSD"
	@echo "  cross-netbsd           - Build for NetBSD"
	@echo "  cross-all              - Build for all cross-compilation targets"
	@echo ""
	@echo "CI/CD:"
	@echo "  ci                     - Full CI pipeline (clean + build + all tests)"
	@echo "  clean                  - Remove build artifacts"
