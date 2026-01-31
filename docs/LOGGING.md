# Logging System Documentation

Sidedoor uses a unified logging library for consistent logging across all scripts with automatic credential masking and file-based audit trails.

---

## Overview

**Location**: `scripts/lib/logging.sh` (~450 lines)

**Features**:
- Unified logging functions for all scripts
- File-based logging with ISO 8601 timestamps
- Automatic credential masking for sensitive data
- Log levels: INFO, WARN, ERROR, DEBUG
- System information capture in log headers
- Automatic log file rotation (timestamped filenames)
- Forensic audit trail preservation

---

## Log Files

### Location

```
/var/log/sidedoor/
├── install.2026-01-31T13-58-00Z.log
├── setup.2026-01-31T14-02-15Z.log
├── sidedoor.2026-01-31T14-15-30Z.log
└── uninstall.2026-01-31T15-30-45Z.log
```

### Format

- **Filename**: `{script_name}.{ISO8601_TIMESTAMP}.log`
- **Example**: `setup.2026-01-31T14-02-15Z.log`
- **Permissions**: `600` (owner read/write only)

### Log Entry Format

```
{TIMESTAMP} [{LEVEL}] [{script:line}] {MESSAGE}
```

**Example**:
```
2026-01-31T14:02:15.123Z [INFO] [setup:145] Creating service user: ubuntu
2026-01-31T14:02:16.456Z [WARN] [setup:167] User ubuntu already exists
2026-01-31T14:02:17.789Z [ERROR] [setup:189] Failed to create directory
```

---

## Usage

### Basic Setup

```bash
# Source the library
source scripts/lib/logging.sh

# Initialize logging for your script
init_logging "my_script_name"

# Use logging functions
log "INFO" "Starting process" "$LINENO"
log "WARN" "This is a warning" "$LINENO"
log "ERROR" "This is an error" "$LINENO"
log "DEBUG" "Debug information" "$LINENO"

# Automatic cleanup on exit
# (trap is set automatically)
```

### Convenience Functions

```bash
# These are equivalent to log() with predefined levels
info "Informational message"
warn "Warning message"
error "Error message"
debug "Debug message"  # Only shown if DEBUG=true

# Phase/header messages
phase "PHASE 1: Installation"
header "Setup Process"
```

### With Line Numbers

```bash
# For better debugging, include line numbers
log "INFO" "Creating user" "$LINENO"
info "User created successfully" "$LINENO"
```

---

## Log Levels

| Level | Color | Console | File | Description |
|-------|-------|----------|------|-------------|
| INFO | Green | Yes | Yes | Normal operations |
| WARN | Yellow | Yes | Yes | Warnings, non-critical issues |
| ERROR | Red | Yes | Yes | Errors, failures |
| DEBUG | Cyan | No* | Yes | Debug info (DEBUG=true only) |

*Debug messages only show in console when `DEBUG=true` environment variable is set.

---

## Credential Masking

The logging library automatically masks sensitive data in log files.

### What Gets Masked

| Pattern | Example | Masked As |
|---------|---------|-----------|
| `authenticatorToken` | `"authenticatorToken": "si1234567890"` | `"authenticatorToken": "***MASKED**"` |
| `cronSecret` | `"cronSecret": "secret123"` | `"cronSecret": "***MASKED**"` |
| Bearer tokens | `Bearer si1234567890` | `Bearer ***MASKED**` |
| API keys | `api_key: abcd1234` | `api_key: ***MASKED**` |
| Passwords | `password: secret123` | `password: ***MASKED**` |
| Private key paths | `/home/user/.ssh/id_rsa` | `/home/user/.ssh/id_***KEY***` |
| SSH keys | `ssh-rsa AAAAB3Nza...` | `ssh-rsa ***KEY*** ***REDACTED***` |

### Masking Format

**Partial Masking** (first 2 + last 2 characters):
```bash
password123 -> pa******23
si******0r   # 10+ chars
ab***cd      # 4-8 chars
```

**Complete Masking** (for tokens/secrets):
```bash
***MASKED***
```

### Manual Masking

```bash
# Mask a specific value
masked=$(log_value "authenticatorToken" "$token_value")
log "INFO" "Using token: $masked"

# Mask entire message
masked_msg=$(mask_sensitive "Token: si1234567890")
log "INFO" "$masked_msg"
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_DIR` | `/var/log/sidedoor` | Override log directory |
| `NO_LOG_FILE` | `false` | Disable file logging |
| `LOG_TIMESTAMP` | `true` | Disable timestamps in output |
| `DEBUG` | `false` | Enable debug output to console |

### Examples

```bash
# Use different log directory
LOG_DIR=/tmp/sidedoor-logs ./scripts/setup.sh --user ubuntu

# Disable file logging
NO_LOG_FILE=true ./scripts/setup.sh --user ubuntu

# Enable debug output
DEBUG=true ./scripts/setup.sh --user ubuntu
```

---

## Log File Structure

### Header

Each log file starts with a header containing system information:

```
============================================
  Sidedoor Log: setup
  Started: 2026-01-31T14:02:15.123Z
============================================

System Information:
  Hostname: ubuntu-s-1vcpu-1gb-nyc1-01
  OS: Ubuntu 24.04 LTS
  Kernel: 6.8.0-1015-azure
  User: root
  PID: 12345

Script Information:
  Name: setup
  Path: /tmp/sidedoor-bootstrap/scripts/setup.sh
  Arguments: --user ubuntu

============================================
```

### Body

Main log entries with timestamps and line numbers:

```
2026-01-31T14:02:15.234Z [INFO] [setup:145] Creating service user: ubuntu
2026-01-31T14:02:15.456Z [INFO] [setup:147] User ubuntu already exists
2026-01-31T14:02:15.567Z [INFO] [setup:150] Checking group membership...
2026-01-31T14:02:15.678Z [INFO] [setup:152] Adding user to sudo group
```

### Footer

Each log file ends with a summary:

```
============================================
  Log Ended: 2026-01-31T14:05:30.789Z
  Log File: /var/log/sidedoor/setup.2026-01-31T14-02-15Z.log
============================================
```

---

## Scripts Using Logging

| Script | Log Prefix | Description |
|--------|------------|-------------|
| `install.sh` | `install` | Bootstrap installation |
| `setup.sh` | `setup` | System setup and configuration |
| `uninstall.sh` | `uninstall` | Removal and cleanup |
| `ssh-migrate.sh` | `ssh-migrate` | SSH key migration |
| `systemd-helper.sh` | `systemd-helper` | Systemd timer management |

---

## Viewing Logs

### Recent Logs

```bash
# View most recent log for a script
sudo tail -f /var/log/sidedoor/setup.*.log

# View last 50 lines
sudo tail -n 50 /var/log/sidedoor/setup.*.log
```

### All Logs

```bash
# List all logs
sudo ls -la /var/log/sidedoor/

# View all logs
sudo less /var/log/sidedoor/*.log
```

### Search Logs

```bash
# Search for errors
sudo grep ERROR /var/log/sidedoor/*.log

# Search for a specific user
sudo grep "ubuntu" /var/log/sidedoor/setup.*.log

# Search for masked tokens
sudo grep MASKED /var/log/sidedoor/*.log
```

### Filter by Log Level

```bash
# Only errors
sudo grep "\[ERROR\]" /var/log/sidedoor/setup.*.log

# Only warnings and errors
sudo grep -E "\[WARN\]|\[ERROR\]" /var/log/sidedoor/setup.*.log
```

---

## Forensic Audit Trail

Logs are **preserved during uninstall** for forensic audit trail.

### What Gets Logged

- Script execution timestamps
- System information (hostname, OS, kernel)
- All operations with line numbers
- Sensitive data (masked)
- Error conditions
- State changes

### Compliance

- ISO 8601 timestamps for precise timing
- System information for attribution
- Line numbers for code traceability
- Credential masking for security
- Persistent logs for audit

---

## Advanced Usage

### Custom Log Directory

```bash
# For testing or development
LOG_DIR=/tmp/sidedoor-test-logs ./scripts/setup.sh --user ubuntu
```

### Disable File Logging

```bash
# For scripts that don't need persistent logs
NO_LOG_FILE=true ./scripts/setup.sh --user ubuntu
```

### Debug Mode

```bash
# Enable debug output to console
DEBUG=true ./scripts/setup.sh --user ubuntu
```

### Conditional Logging

```bash
# Only log debug if enabled
debug "Detailed debug info" "$LINENO"

# Always log to file, console only if DEBUG=true
```

---

## Troubleshooting

### Permission Denied

```bash
# Check log directory permissions
sudo ls -la /var/log/sidedoor/

# Expected: drwx------ (700) owned by root
```

### No Log Files Created

```bash
# Check if file logging is disabled
echo $NO_LOG_FILE

# Check log directory exists
sudo ls -la /var/log/sidedoor/

# Check disk space
df -h /var/log/
```

### Corrupted Log Files

```bash
# Check log file integrity
sudo file /var/log/sidedoor/setup.*.log

# Expected: ASCII text, UTF-8 Unicode text
```

---

## Best Practices

1. **Always initialize logging** at the start of your script
2. **Include line numbers** for debugging
3. **Use appropriate log levels** (INFO, WARN, ERROR, DEBUG)
4. **Never log sensitive data** directly (library handles it)
5. **Use phase()** for major steps
6. **Check logs first** when troubleshooting
7. **Preserve logs** for forensic audit trail
