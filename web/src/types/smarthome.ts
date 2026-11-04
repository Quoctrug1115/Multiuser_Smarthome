export type UserRole = 'Owner' | 'Member' | 'Guest';

export interface Device {
  id: string;
  name: string;
  room_name: string;
  device_type: 'SWITCH' | 'SENSOR' | 'LOCK' | 'DIMMER';
  status: boolean;
  power_watt: number;
  value?: number;
}

export interface AIAlert {
  id: string;
  alert_type: string;
  severity: 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL';
  message: string;
  created_at: string;
}

export interface AutomationRule {
  id: string;
  name: string;
  trigger_device_id: string;
  condition_type: 'GREATER_THAN' | 'LESS_THAN' | 'EQUALS';
  trigger_value: number;
  action_device_id: string;
  is_active: boolean;
}