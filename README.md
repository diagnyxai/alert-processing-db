# Alert Processing Database

## Overview
Database repository for the Alert Processing Service handling alert configurations, triggers, state management, and processing queues.

## Database Tables

### Core Alert Tables
- `alerts` - Alert configurations and rules
- `alert_triggers` - Threshold breach tracking with performance metrics
- `alert_state_history` - Complete audit trail of state transitions
- `alert_conditions` - Alert condition definitions

### Processing Infrastructure
- `alert_processing_queue` - Scalable background job queue
- `alert_evaluation_cache` - Optimization cache for repeated evaluations
- `alert_worker_leases` - Worker coordination and lease management
- `alert_batch_processing` - Batch processing tracking

### Suppression & Deduplication
- `alert_suppression_rules` - Intelligent suppression and deduplication
- `alert_escalation_rules` - Alert escalation configurations
- `alert_dependencies` - Alert dependency mapping
- `alert_maintenance_windows` - Maintenance window configurations

### Monitoring & Analytics
- `alert_system_metrics` - Performance and operational metrics
- `alert_performance_stats` - Processing performance statistics
- `alert_false_positive_tracking` - False positive analysis
- `alert_effectiveness_metrics` - Alert effectiveness tracking

## Key Features
- Multi-level thresholds (warning/critical)
- Consecutive breach tracking with configurable duration
- False positive reduction through statistical analysis
- Complete alert lifecycle management
- Auto-scaling recommendations based on performance
- Comprehensive audit trails and analytics

## Technology Stack
- PostgreSQL 15+
- TimescaleDB extension for time-series data
- UUID primary keys
- Composite indexes for query optimization
- Trigger functions for automated state management
- Row Level Security (RLS)

## Setup
```bash
# Create database with TimescaleDB
createdb alert_processing_db
psql -d alert_processing_db -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

# Run migrations
psql -d alert_processing_db -f migrations/001_initial_setup.sql
psql -d alert_processing_db -f migrations/002_alert_core_tables.sql
psql -d alert_processing_db -f migrations/003_processing_infrastructure.sql
psql -d alert_processing_db -f migrations/004_suppression_tables.sql
psql -d alert_processing_db -f migrations/005_monitoring_tables.sql
``` 