-- =============================================================================
-- Diagnyx Alert Processing Database Schema
-- Migration: V2__alert_processing_queue_schema.sql
-- =============================================================================

-- 1. Alert Processing Queue Table
CREATE TABLE IF NOT EXISTS public.alert_processing_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id UUID NOT NULL REFERENCES public.alerts(id) ON DELETE CASCADE,
  evaluation_type TEXT NOT NULL CHECK (evaluation_type IN ('scheduled', 'manual', 'threshold_breach')),
  priority INTEGER DEFAULT 5,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  scheduled_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  processed_at TIMESTAMP WITH TIME ZONE,
  attempts INTEGER DEFAULT 0,
  max_attempts INTEGER DEFAULT 3,
  worker_id TEXT,
  error_message TEXT,
  processing_result JSONB,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Alert Processing Metrics Table
CREATE TABLE IF NOT EXISTS public.alert_processing_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  metric_name TEXT NOT NULL,
  metric_value DOUBLE PRECISION NOT NULL,
  metric_unit TEXT NOT NULL DEFAULT 'count',
  category TEXT NOT NULL,
  subcategory TEXT,
  tags JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_alert_processing_queue_alert_id ON public.alert_processing_queue(alert_id);
CREATE INDEX IF NOT EXISTS idx_alert_processing_queue_status ON public.alert_processing_queue(status);
CREATE INDEX IF NOT EXISTS idx_alert_processing_queue_scheduled_at ON public.alert_processing_queue(scheduled_at);
CREATE INDEX IF NOT EXISTS idx_alert_processing_metrics_name ON public.alert_processing_metrics(metric_name);
CREATE INDEX IF NOT EXISTS idx_alert_processing_metrics_category ON public.alert_processing_metrics(category);
CREATE INDEX IF NOT EXISTS idx_alert_processing_metrics_created_at ON public.alert_processing_metrics(created_at);

-- Create triggers for updated_at columns
CREATE TRIGGER update_alert_processing_queue_updated_at
  BEFORE UPDATE ON public.alert_processing_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- 3. Alert Processing Functions

-- Queue an alert for evaluation
CREATE OR REPLACE FUNCTION public.queue_alert_evaluation(
  p_alert_id UUID,
  p_evaluation_type TEXT DEFAULT 'scheduled',
  p_priority INTEGER DEFAULT 5,
  p_scheduled_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  queue_id UUID;
BEGIN
  -- Verify alert exists
  IF NOT EXISTS (SELECT 1 FROM public.alerts WHERE id = p_alert_id) THEN
    RAISE EXCEPTION 'Alert with ID % not found', p_alert_id;
  END IF;

  -- Insert into processing queue
  INSERT INTO public.alert_processing_queue (
    alert_id, evaluation_type, priority, scheduled_at
  )
  VALUES (
    p_alert_id, p_evaluation_type, p_priority, p_scheduled_at
  )
  RETURNING id INTO queue_id;
  
  RETURN queue_id;
END;
$$;

-- Get next batch of alerts to process
CREATE OR REPLACE FUNCTION public.get_next_alert_batch(
  p_batch_size INTEGER DEFAULT 50,
  p_worker_id TEXT DEFAULT NULL
)
RETURNS SETOF public.alert_processing_queue
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH selected_queue AS (
    SELECT id 
    FROM public.alert_processing_queue
    WHERE status = 'pending' 
      AND scheduled_at <= NOW()
      AND attempts < max_attempts
    ORDER BY priority, scheduled_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.alert_processing_queue q
  SET 
    status = 'processing',
    worker_id = p_worker_id,
    attempts = attempts + 1
  FROM selected_queue sq
  WHERE q.id = sq.id
  RETURNING q.*;
END;
$$;

-- Record a metric for alert system
CREATE OR REPLACE FUNCTION public.record_alert_system_metric(
  p_metric_name TEXT,
  p_metric_value DOUBLE PRECISION,
  p_metric_unit TEXT DEFAULT 'count',
  p_category TEXT DEFAULT 'processing_time',
  p_subcategory TEXT DEFAULT NULL,
  p_tags JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  metric_id UUID;
BEGIN
  INSERT INTO public.alert_processing_metrics (
    metric_name, metric_value, metric_unit, 
    category, subcategory, tags
  )
  VALUES (
    p_metric_name, p_metric_value, p_metric_unit,
    p_category, p_subcategory, p_tags
  )
  RETURNING id INTO metric_id;
  
  RETURN metric_id;
END;
$$;

-- Process an alert batch (mock implementation as the actual processing will be done in the service)
CREATE OR REPLACE FUNCTION public.process_alert_batch()
RETURNS TABLE (
  processed_count INTEGER,
  triggered_count INTEGER,
  error_count INTEGER,
  processing_time_ms INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- This is a placeholder - the actual processing will be done by the service
  -- This function will just be used to track metrics and results
  
  RETURN QUERY
  SELECT 
    0 AS processed_count, 
    0 AS triggered_count, 
    0 AS error_count, 
    0 AS processing_time_ms;
END;
$$;

-- Get alert system health
CREATE OR REPLACE FUNCTION public.get_alert_system_health()
RETURNS TABLE (
  queue_size INTEGER,
  processing_rate DOUBLE PRECISION,
  error_rate DOUBLE PRECISION,
  avg_processing_time_ms DOUBLE PRECISION,
  queue_lag_seconds INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH queue_metrics AS (
    SELECT 
      COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
      COUNT(*) FILTER (WHERE status = 'processing') AS processing_count,
      COUNT(*) FILTER (WHERE status = 'failed') AS failed_count,
      COUNT(*) FILTER (WHERE status = 'completed') AS completed_count,
      EXTRACT(EPOCH FROM NOW() - MIN(scheduled_at)) FILTER (WHERE status = 'pending') AS oldest_pending_seconds
    FROM public.alert_processing_queue 
    WHERE created_at > NOW() - INTERVAL '24 HOURS'
  ),
  processing_metrics AS (
    SELECT 
      AVG(metric_value) FILTER (WHERE metric_name = 'processing_time_ms') AS avg_time_ms,
      SUM(metric_value) FILTER (WHERE metric_name = 'alerts_processed' AND created_at > NOW() - INTERVAL '1 HOUR') AS processed_last_hour,
      SUM(metric_value) FILTER (WHERE metric_name = 'alerts_error' AND created_at > NOW() - INTERVAL '1 HOUR') AS errors_last_hour
    FROM public.alert_processing_metrics
    WHERE created_at > NOW() - INTERVAL '24 HOURS'
  )
  SELECT 
    COALESCE(qm.pending_count, 0) AS queue_size,
    COALESCE(pm.processed_last_hour / 3600.0, 0) AS processing_rate,
    CASE 
      WHEN COALESCE(pm.processed_last_hour, 0) = 0 THEN 0
      ELSE COALESCE(pm.errors_last_hour / NULLIF(pm.processed_last_hour, 0), 0)
    END AS error_rate,
    COALESCE(pm.avg_time_ms, 0) AS avg_processing_time_ms,
    COALESCE(qm.oldest_pending_seconds, 0)::INTEGER AS queue_lag_seconds
  FROM queue_metrics qm
  CROSS JOIN processing_metrics pm;
END;
$$;

-- Clean up old alert data
CREATE OR REPLACE FUNCTION public.cleanup_alert_data()
RETURNS TABLE (
  table_name TEXT,
  records_deleted INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_count INTEGER;
  total_deleted INTEGER := 0;
BEGIN
  -- Clean up old processing queue data
  DELETE FROM public.alert_processing_queue
  WHERE status IN ('completed', 'failed')
    AND created_at < NOW() - INTERVAL '30 DAYS';
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  
  IF deleted_count > 0 THEN
    RETURN QUERY SELECT 'alert_processing_queue'::TEXT, deleted_count;
    total_deleted := total_deleted + deleted_count;
  END IF;
  
  -- Clean up old processing metrics
  DELETE FROM public.alert_processing_metrics
  WHERE created_at < NOW() - INTERVAL '90 DAYS';
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  
  IF deleted_count > 0 THEN
    RETURN QUERY SELECT 'alert_processing_metrics'::TEXT, deleted_count;
    total_deleted := total_deleted + deleted_count;
  END IF;
  
  -- If no records were deleted, return empty result
  IF total_deleted = 0 THEN
    RETURN QUERY SELECT 'none'::TEXT, 0;
  END IF;
END;
$$; 