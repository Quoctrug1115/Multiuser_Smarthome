export type UserRole = 'Admin' | 'Member' | 'Guest';
export type TabType = 'overview' | 'devices' | 'automations' | 'energy' | 'ai' | 'accounts';

export interface UserAccount {
  id: string;
  name: string;
  email: string;
  role: UserRole;
  created_at?: string;
}

export interface House {
  id: string;
  name: string;
  address: string;
  owner_id: string;
  created_at?: string;
}

export interface Room {
  id: string;
  house_id: string;
  house_name?: string;
  name: string;
  floor: number;
}

export interface Device {
  id: string;
  name: string;
  room_id?: string | null;
  room_name: string;
  device_type: string;
  status: boolean;
  power_watt: number;
  topic: string;
  brightness?: number;
}

export interface DiscoveredWokwiDevice {
  name: string;
  device_type: string;
  mqtt_topic: string;
  chip?: string;
}

export interface AIAlert {
  id: string;
  alert_type: string;
  message: string;
  created_at: string;
  severity?: string;
}

export interface AutomationRule {
  id: string;
  name: string;
  condition_text: string;
  action_text: string;
  is_active: boolean;
}

export interface EnergyAnalytics {
  labels: string[];
  kwh_data: number[];
  total_kwh: number;
  total_vnd: number;
}