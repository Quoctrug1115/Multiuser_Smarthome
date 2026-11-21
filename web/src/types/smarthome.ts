export interface UserProfile {
  id: string;
  name: string;
  full_name?: string;
  email: string;
  role: string;
  owner_id?: string | null;
}

export interface ExcelUserPreviewItem {
  rowNumber: number;
  name: string;
  email: string;
  password: string;
  isDefaultPassword: boolean;
  role: 'Admin' | 'Member' | 'Guest';
  isValid: boolean;
  errorReason?: string;
}

export interface ExcelSpacePreviewItem {
  id: string;
  sheetName: string;
  rowNumber: number;
  kind: 'house' | 'room' | 'device';
  name: string;
  address?: string;
  houseName?: string;
  roomName?: string;
  floor?: number;
  deviceType?: string;
  mqttTopic?: string;
  isValid: boolean;
  errorReason?: string;
}

export interface House {
  id: string;
  name: string;
  address: string;
  owner_id?: string | null;
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
  device_type: string;
  mqtt_topic: string;
  room_id?: string | null;
  room_name?: string | null;
  is_on: boolean;
  is_online?: boolean;
}

export interface AutomationRule {
  id: string;
  name: string;
  condition_text: string;
  action_text: string;
  condition_type?: string;
  operator?: string;
  threshold?: number;
  action?: string;
  is_active: boolean;
}

export interface AiAlert {
  id: string;
  alert_type: string;
  title?: string;
  message: string;
  severity?: string;
  created_at: string;
}

export interface EnergyPoint {
  label: string;
  kwh: number;
  power_watt?: number;
}

export interface EnergyState {
  total_kwh: number;
  estimated_cost: number;
  peak_watt?: number;
  daily: EnergyPoint[];
}

export interface SensorData {
  temperature: number;
  humidity: number;
  lux: number;
  motion: boolean;
}

export type ActiveTab = 'overview' | 'devices' | 'automations' | 'energy' | 'ai' | 'accounts';