-- =============================================================================
-- Diagnyx Alert Processing Database Schema
-- Migration: V1__alert_processing_schema.sql
-- =============================================================================

-- Create update_updated_at_column function if it doesn't exist
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Enable TimescaleDB extension (already done in database setup script, but included for completeness)
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- 1. Alert System Tables
CREATE TABLE IF NOT EXISTS public.alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  api_id UUID,
  metric_type TEXT NOT NULL CHECK (metric_type IN ('response_time', 'error_rate', 'uptime')),
  comparison_operator TEXT NOT NULL CHECK (comparison_operator IN ('>', '<', '>=', '<=', '=')),
  threshold_value NUMERIC NOT NULL,
  threshold_unit TEXT NOT NULL,
  is_active BOOLEAN DEFAULT true,
  consecutive_breaches_required INTEGER DEFAULT 1,
  evaluation_window_minutes INTEGER DEFAULT 5,
  notification_enabled BOOLEAN DEFAULT false,
  notification_frequency TEXT DEFAULT 'immediate' CHECK (notification_frequency IN ('immediate', '5min', '15min', 'hourly')),
  email_format TEXT DEFAULT 'html' CHECK (email_format IN ('html', 'plain', 'mobile')),
  severity_filter TEXT DEFAULT 'high-critical' CHECK (severity_filter IN ('critical', 'high-critical', 'all')),
  quiet_hours_enabled BOOLEAN DEFAULT false,
  quiet_hours_start TIME DEFAULT '22:00',
  quiet_hours_end TIME DEFAULT '08:00',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own alerts" ON public.alerts
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can manage their own alerts" ON public.alerts
  FOR ALL USING (user_id = auth.uid());

CREATE TABLE IF NOT EXISTS public.alert_triggers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id UUID NOT NULL REFERENCES public.alerts(id) ON DELETE CASCADE,
  triggered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metric_value NUMERIC NOT NULL,
  breach_count INTEGER DEFAULT 1,
  severity TEXT DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  resolved_at TIMESTAMPTZ,
  resolution_type TEXT CHECK (resolution_type IN ('automatic', 'manual', 'timeout')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.alert_triggers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view triggers for their alerts" ON public.alert_triggers
  FOR SELECT USING (
    alert_id IN (SELECT id FROM public.alerts WHERE user_id = auth.uid())
  );

-- 2. Activity & Monitoring Tables
CREATE TABLE public.activity_log (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  activity_type TEXT NOT NULL CHECK (activity_type IN (
    'api_added', 'api_status_changed', 'alert_triggered', 'error_detected',
    'api_removed', 'alert_created', 'alert_resolved', 'performance_degraded',
    'performance_improved', 'incident_created', 'incident_resolved'
  )),
  description TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  api_id UUID,
  target_id UUID,
  severity TEXT CHECK (severity IN ('info', 'warning', 'error', 'success')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.activity_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own activity log" 
  ON public.activity_log 
  FOR SELECT 
  USING (auth.uid() = user_id);

-- 3. Incident Management
CREATE TABLE public.incidents (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  api_id UUID,
  user_id UUID NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'investigating', 'resolved')),
  title TEXT NOT NULL,
  description TEXT,
  error_pattern TEXT,
  threshold_breached NUMERIC,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  resolved_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.incidents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own incidents" 
  ON public.incidents 
  FOR SELECT 
  USING (auth.uid() = user_id);

CREATE POLICY "Users can manage their own incidents" 
  ON public.incidents 
  FOR ALL 
  USING (auth.uid() = user_id);

-- 4. Background Jobs
CREATE TABLE public.background_jobs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  job_type TEXT NOT NULL,
  job_data JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  priority INTEGER NOT NULL DEFAULT 5,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  attempts INTEGER NOT NULL DEFAULT 0,
  scheduled_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  started_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  failed_at TIMESTAMP WITH TIME ZONE,
  error_message TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create triggers for updated_at columns
CREATE TRIGGER update_alerts_updated_at
  BEFORE UPDATE ON public.alerts
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_incidents_updated_at
  BEFORE UPDATE ON public.incidents
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_background_jobs_updated_at
  BEFORE UPDATE ON public.background_jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Activity logging function
CREATE OR REPLACE FUNCTION public.log_activity(
  p_user_id UUID,
  p_activity_type TEXT,
  p_description TEXT,
  p_metadata JSONB DEFAULT '{}',
  p_api_id UUID DEFAULT NULL,
  p_target_id UUID DEFAULT NULL,
  p_severity TEXT DEFAULT 'info'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  activity_id UUID;
BEGIN
  INSERT INTO public.activity_log (
    user_id, activity_type, description, metadata, 
    api_id, target_id, severity
  ) VALUES (
    p_user_id, p_activity_type, p_description, p_metadata,
    p_api_id, p_target_id, p_severity
  )
  RETURNING id INTO activity_id;
  
  RETURN activity_id;
END;
$$;

-- Create indexes for better performance
CREATE INDEX idx_alerts_user_id ON public.alerts(user_id);
CREATE INDEX idx_alerts_api_id ON public.alerts(api_id);
CREATE INDEX idx_alerts_is_active ON public.alerts(is_active);
CREATE INDEX idx_alert_triggers_alert_id ON public.alert_triggers(alert_id);
CREATE INDEX idx_alert_triggers_triggered_at ON public.alert_triggers(triggered_at);
CREATE INDEX idx_activity_log_user_id ON public.activity_log(user_id);
CREATE INDEX idx_activity_log_activity_type ON public.activity_log(activity_type);
CREATE INDEX idx_activity_log_created_at ON public.activity_log(created_at);
CREATE INDEX idx_incidents_user_id ON public.incidents(user_id);
CREATE INDEX idx_incidents_api_id ON public.incidents(api_id);
CREATE INDEX idx_incidents_status ON public.incidents(status);
CREATE INDEX idx_background_jobs_status ON public.background_jobs(status);
CREATE INDEX idx_background_jobs_scheduled_at ON public.background_jobs(scheduled_at); 