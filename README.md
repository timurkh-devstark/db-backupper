# db-backupper - PostgreSQL Docker Backup & Restore Tool for S3

A professional, modular tool that automates PostgreSQL database backup and restore operations with Amazon S3 storage. Features a clean architecture with separate modules for maintainability and easy deployment.

## Features

- **Modular Architecture**: Clean separation of concerns with dedicated modules for configuration, database operations, backup, and restore functionality
- **Global Command**: Install as `db-backupper` command available system-wide or per-user
- **Cron-Ready**: Enhanced PATH handling and logging for reliable automated backups
- **User-Scoped Configuration**: Active configs live under `~/.config/db-backupper`
- **Comprehensive Error Handling**: Robust error checking and informative logging
- **Legacy Compatibility**: Maintains all existing functionality while improving structure

## Prerequisites

1. **Bash**: The tool is written for Bash shell
2. **AWS CLI**: Installed and configured with appropriate S3 permissions
   - Install: https://aws.amazon.com/cli/
   - Configure: See AWS Setup section below
3. **Docker**: Installed and running with PostgreSQL container
   - Install: https://docs.docker.com/get-docker/
4. **tar utility**: Usually pre-installed on Linux/macOS
5. **PostgreSQL Client Tools**: Must be available inside the PostgreSQL Docker container (standard PostgreSQL images include these)

## Quick Start

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/timurkhakhalev/db-backupper db-backupper
   cd db-backupper
   ```

2. **Install globally (recommended):**
   ```bash
   sudo ./install.sh
   ```
   This installs the binary system-wide, but active configs are still created under the invoking user's `~/.config/db-backupper`.
   
   Or install for current user only:
   ```bash
   ./install.sh --user
   ```

3. **Configure:**
   ```bash
   # Legacy mode: edit the user-scoped configuration file
   nano ~/.config/db-backupper/backup.conf

   # Project mode: copy the project template and create one file per project
   cp ~/.config/db-backupper/projects/example.conf ~/.config/db-backupper/projects/app-prod.conf
   ```

### Basic Usage

```bash
# Create a backup with legacy backup.conf
db-backupper backup

# Run setup wizard for fresh setup or migration into ~/.config
db-backupper setup

# Validate cron readiness for the active config
db-backupper --project app-prod check-cron

# Install or replace a managed cron backup job
db-backupper --project app-prod install-cron --schedule "0 2 * * *" --prefix "production/"

# List available named project configs
db-backupper list-projects

# Create a backup for a named project
db-backupper --project app-prod backup

# Create a backup with prefix for organization
db-backupper --project app-prod backup --prefix "production/"

# Download a backup
db-backupper --project app-prod download s3://your-bucket/path/to/backup.tar.gz

# Restore a backup (with interactive purge option)
db-backupper --project app-prod restore ./dump_dbname_20241201_120000.sql

# Restore with automatic database purging
db-backupper --project app-prod restore ./dump_dbname_20241201_120000.sql --purge
```

## Configuration

### Legacy Configuration File Location

If `--project` is not provided, the tool uses:
1. `~/.config/db-backupper/backup.conf`

### Project Configuration File Location

If `--project <name>` is provided, the tool uses:
1. `~/.config/db-backupper/projects/<name>.conf`

### Configuration Variables

Legacy and project config files use the same variables:

```bash
# AWS Configuration
AWS_PROFILE="your-aws-profile"           # AWS CLI profile name
S3_BUCKET_NAME="your-s3-bucket-name"     # S3 bucket for backups
S3_BACKUP_PATH="postgres_dumps/"         # Optional S3 path prefix
S3_RETENTION_KEEP_LAST="7"               # Keep the newest 7 successful backups
S3_ADDITIONAL_TARGETS="r2"               # Optional space-separated target names

# PostgreSQL Configuration  
POSTGRES_URI="postgresql://user:password@localhost:5432/dbname"
DOCKER_CONTAINER_NAME="your_postgres_container_name"
```

### Multiple S3 Targets

One backup run creates one archive and uploads it to the configured primary bucket
and every name in `S3_ADDITIONAL_TARGETS`. For example:

```bash
S3_ADDITIONAL_TARGETS="r2 offsite"
```

Each additional target has a file at `~/.config/db-backupper/targets/<name>.conf`:

```bash
# ~/.config/db-backupper/targets/r2.conf
AWS_PROFILE="r2"
S3_BUCKET_NAME="timur-backups"
S3_BACKUP_PATH="aicoding/postgres_dumps/"
S3_RETENTION_KEEP_LAST="0"
```

Copy `target.conf.example` to that path and restrict the file to mode `600`.
Target files accept only the four storage settings shown above; database settings
stay in the project config. Target names may contain letters, digits, hyphens and
underscores. Set a different prefix for each project's files in a shared bucket.
The command-line `--prefix` is appended to each target's `S3_BACKUP_PATH`.

Configure each provider's endpoint in its AWS CLI profile, so all upload,
verification and retention requests go to the same provider. For R2 in the EU:

```ini
# ~/.aws/config
[profile r2]
region = auto
endpoint_url = https://<ACCOUNT_ID>.eu.r2.cloudflarestorage.com
```

Store the R2 S3 access key and secret in `~/.aws/credentials` under `[r2]`.
See [AWS CLI endpoint configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-endpoints.html).

All target configs are validated before dumping. Uploads run sequentially, and a
failed upload does not skip other targets. Each uploaded object is checked against
the local archive size. The command succeeds only if every upload, verification
and enabled retention operation succeeds. On partial failure it exits nonzero and
logs the retained local archive path for manual retry. It does not retry uploads
automatically or clean up these retained archives.

Cloudflare R2 does not support S3 object tags. Use `S3_RETENTION_KEEP_LAST="0"`
to disable retention tagging for that target and configure expiration with R2
lifecycle rules. This does not disable upload verification. Bucket locks and
client-side encryption are separate settings; this feature does not enable them.
See [R2 S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/).

Downloads use the primary AWS profile from the selected project config. To restore
from an additional target, download with `aws s3 cp --profile r2`, extract the
archive, then run `db-backupper restore` on the SQL dump.

## AWS Setup

### Setting Up AWS Profile on EC2/Server Instance

#### Option 1: Using AWS CLI with Access Keys
```bash
# Install AWS CLI if not already installed
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Configure AWS profile
aws configure --profile db-backupper
# Enter your AWS Access Key ID, Secret Access Key, region, and output format
```

#### Option 2: Using IAM Role (Recommended for EC2)
```bash
# Attach IAM role to your EC2 instance with S3 permissions
# No additional configuration needed - use "default" profile

# Verify IAM role permissions
aws sts get-caller-identity
aws s3 ls s3://your-bucket-name --profile default
```

### Required IAM Permissions

Your AWS user/role needs these S3 permissions:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:GetObjectTagging",
                "s3:PutObjectTagging"
            ],
            "Resource": [
                "arn:aws:s3:::your-bucket-name",
                "arn:aws:s3:::your-bucket-name/*"
            ]
        }
    ]
}
```

### Troubleshooting AWS Authentication

1. **Check AWS CLI installation**: `aws --version`
2. **List configured profiles**: `aws configure list-profiles`
3. **Test S3 access**: `aws s3 ls --profile your-profile-name`
4. **Check credentials file**: `cat ~/.aws/credentials`
5. **For EC2 instances**: Verify IAM role is attached in EC2 console

## Advanced Usage

### Keep the Last N Successful Backups

Every target requires an explicit `S3_RETENTION_KEEP_LAST` value: a positive integer
enables keep-last tagging, and `0` disables tagging. Retention is applied
independently for each target, S3 path, command-line prefix, and database name.

After the archive upload completes, `db-backupper` verifies the remote object size and then applies these tags:

1. The newest N matching archives receive `db-backupper-retention=active`.
2. Older matching archives receive `db-backupper-retention=expired`.
3. No S3 object is deleted directly by `db-backupper`.
4. If dump creation, upload, or upload verification fails, retention is not run.

Configure the bucket lifecycle to expire only objects carrying the `expired` tag. For a real recovery window, enable S3 bucket versioning and use a rule like this:

```json
{
  "ID": "db-backupper-expired",
  "Status": "Enabled",
  "Filter": {
    "Tag": {
      "Key": "db-backupper-retention",
      "Value": "expired"
    }
  },
  "Expiration": {
    "Days": 1
  },
  "NoncurrentVersionExpiration": {
    "NoncurrentDays": 7
  }
}
```

Merge this rule into the bucket's existing lifecycle configuration. AWS `put-bucket-lifecycle-configuration` replaces the complete configuration, so do not submit this rule by itself when the bucket already has unrelated rules.

`Expiration.Days` is calculated from the object's original creation time, not from the moment the `expired` tag is added. With versioning enabled, lifecycle creates a delete marker and the previous object version remains recoverable for `NoncurrentDays`. Without versioning, an old object can be permanently expired as soon as lifecycle processes its new tag.

Disable age-based expiration rules that target the entire backup prefix. Such rules ignore the `active` tag and can still delete the protected newest N backups.

### Automated Backups with Cron

Create automated backups using the built-in managed cron installer:

```bash
# Validate that cron execution will work for the active config
db-backupper --project app-prod check-cron

# Install or replace a managed cron job
db-backupper --project app-prod install-cron --schedule "0 2 * * *" --prefix "production/"

# Inspect example cron lines without installing them
db-backupper --project app-prod crontab
```

`install-cron` writes a managed entry into the current user's crontab and runs a cron-style self-check first, so it refuses to install the job if the active config, executable path, required commands, or log path are not cron-ready.

### Command Reference

#### Backup Commands
```bash
# Basic backup with legacy config
db-backupper backup

# Basic backup with a project config
db-backupper --project app-prod backup

# Backup with S3 path prefix
db-backupper --project app-prod backup --prefix "production/"
db-backupper --project app-prod backup --prefix "weekly/2024/"
```

#### Setup Commands
```bash
# Run interactive setup wizard
db-backupper setup

# Keep existing legacy mode explicitly
db-backupper setup --mode legacy

# Create a named project from current legacy backup.conf
db-backupper setup --mode project --name app-prod
```

`setup` supports both fresh setup and migration. If no configured legacy source exists, it bootstraps new config files directly under `~/.config/db-backupper`. If `./backup.conf` or `/etc/db-backupper/backup.conf` exists and is configured, `setup` can migrate from it into the user-scoped runtime config.

#### Cron Commands
```bash
# Validate cron readiness for the active config
db-backupper --project app-prod check-cron

# Install or replace a managed cron job
db-backupper --project app-prod install-cron --schedule "0 2 * * *" --prefix "production/"

# Override the log file if needed
db-backupper --project app-prod install-cron --schedule "0 2 * * *" --prefix "production/" --log-file ~/.local/log/db-backupper/app-prod.log
```

#### Project Discovery
```bash
# List available project configs from ~/.config/db-backupper/projects
db-backupper list-projects
```

#### Download Commands
```bash
# Download to current directory
db-backupper --project app-prod download s3://bucket/path/to/backup.tar.gz

# Download to specific directory
db-backupper --project app-prod download s3://bucket/path/to/backup.tar.gz /path/to/downloads/
```

#### Restore Commands
```bash
# Interactive restore (asks about database purging)
db-backupper --project app-prod restore /path/to/dump_file.sql

# Force purge database before restore
db-backupper --project app-prod restore /path/to/dump_file.sql --purge

# Preserve existing database (merge mode)
db-backupper --project app-prod restore /path/to/dump_file.sql --no-purge

# Legacy restore (deprecated - downloads and restores in one step)
db-backupper --project app-prod restore-legacy s3://bucket/path/to/backup.tar.gz
```

### Example Workflows

#### Standard Backup and Restore Workflow
```bash
# 1. Create backup
db-backupper --project app-prod backup --prefix "before-migration/"

# 2. Later, download the backup
db-backupper --project app-prod download s3://your-bucket/postgres_dumps/before-migration/mydb_20241201_120000.tar.gz

# 3. Restore to database (with purge for clean restore)
db-backupper --project app-prod restore ./dump_mydb_20241201_120000.sql --purge
```

#### Quick Testing Workflow
```bash
# Test backup
db-backupper backup --prefix "test/"

# Test restore (without purging - merges with existing data)
db-backupper restore-legacy s3://your-bucket/postgres_dumps/test/mydb_20241201_120000.tar.gz
```

## Architecture

The tool uses a modular architecture with separate modules for configuration, database operations, backup, and restore functionality. For detailed architecture documentation, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Security Features

This tool implements comprehensive security hardening:

- **Input Validation**: All user inputs are validated to prevent injection attacks
- **Secure Authentication**: Uses `.pgpass` files instead of exposing passwords in process lists
- **Path Security**: Prevents path traversal attacks in S3 prefixes and archive extraction
- **Configuration Security**: Secure configuration parsing prevents code injection
- **Resource Protection**: Monitors disk space and memory usage to prevent resource exhaustion

**Security Best Practices**:
- Configuration files are automatically set to secure permissions (`chmod 600`)
- Use IAM roles when possible instead of access keys
- Limit S3 permissions to specific buckets and required operations
- Ensure proper network segmentation between backup systems and production databases

For security testing and detailed security architecture, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Troubleshooting

### Common Issues

1. **"Command not found" after installation**
   - For user installation: Ensure `~/.local/bin` is in your PATH
   - For system installation: Verify `/usr/local/bin` is in your PATH

2. **AWS authentication errors**
   - Verify AWS CLI installation: `aws --version`
   - Test profile access: `aws s3 ls --profile your-profile-name`
   - Check IAM permissions match requirements above

3. **Docker connection issues**
   - Verify container name: `docker ps`
   - Check container is running: `docker inspect container-name`
   - Ensure PostgreSQL tools are available in container

4. **Database connection errors**
   - Verify POSTGRES_URI format and credentials
   - Test connection from within container
   - Check network connectivity between containers

5. **Backup/restore failures**
   - Check S3 bucket permissions and existence
   - Verify disk space for temporary files
   - Review logs for specific error messages

### Getting Help

```bash
# Show help and usage information
db-backupper help

# Test configuration (dry run)
db-backupper backup --help
```

## Contributing

For development setup, testing procedures, and contribution guidelines, see [DEVELOPMENT.md](DEVELOPMENT.md).

## License

[Add your license information here]

## Changelog

### v2.0.0
- **Major refactor**: Modular architecture with separate lib files
- **Global installation**: Install as `db-backupper` command
- **Enhanced cron support**: Robust PATH handling for automated execution  
- **Flexible configuration**: Multiple config file locations
- **Comprehensive documentation**: Detailed AWS setup and troubleshooting guides
- **Backward compatibility**: All existing functionality preserved

### v1.x
- Original monolithic `db_backup.sh` implementation
- Basic backup and restore functionality
- S3 integration and Docker support
