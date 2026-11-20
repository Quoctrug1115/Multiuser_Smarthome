export const API_BASE = import.meta.env.VITE_API_URL || 'http://127.0.0.1:3000/api/v1';

export const WS_URL =
  import.meta.env.VITE_WS_URL ||
  API_BASE.replace(/^http/, 'ws').replace(/\/api\/v1\/?$/, '/ws');

export function getAuthHeaders(): HeadersInit {
  const token = localStorage.getItem('token') || '';
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
  };
}