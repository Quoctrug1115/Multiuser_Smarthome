import React, { createContext, useContext, useState } from 'react';
import type { UserProfile } from '../types/smarthome';
import { API_BASE } from '../utils/api';

interface AuthContextValue {
  currentUser: UserProfile | null;
  isOwnerOrAdmin: boolean;
  syncUserProfile: (meData: Partial<UserProfile>) => void;
  login: (email: string, password: string) => Promise<UserProfile>;
  register: (name: string, email: string, password: string) => Promise<UserProfile>;
  logout: () => void;
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [currentUser, setCurrentUser] = useState<UserProfile | null>(() => {
    try {
      const saved = localStorage.getItem('smarthome_user');
      return saved ? JSON.parse(saved) : null;
    } catch {
      return null;
    }
  });

  const normalizedRole = (currentUser?.role || '').trim().toLowerCase();
  const isOwnerOrAdmin = normalizedRole === 'owner' || normalizedRole === 'admin';

  const syncUserProfile = (meData: Partial<UserProfile>) => {
    if (!meData?.role) return;
    setCurrentUser((prev) => {
      if (!prev) return prev;
      const updated: UserProfile = {
        ...prev,
        id: meData.id || prev.id,
        name: meData.name || prev.name,
        email: meData.email || prev.email,
        role: meData.role!,
        owner_id: meData.owner_id ?? prev.owner_id,
      };
      localStorage.setItem('smarthome_user', JSON.stringify(updated));
      return updated;
    });
  };

  const login = async (email: string, password: string): Promise<UserProfile> => {
    const res = await fetch(`${API_BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email.trim(), password }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(data?.error || 'Xác thực thất bại, vui lòng thử lại.');
    }
    if (!data?.token || !data?.user) {
      throw new Error('Phản hồi đăng nhập không hợp lệ.');
    }
    localStorage.setItem('token', data.token);
    localStorage.setItem('smarthome_user', JSON.stringify(data.user));
    setCurrentUser(data.user);
    return data.user;
  };

  const register = async (name: string, email: string, password: string): Promise<UserProfile> => {
    const res = await fetch(`${API_BASE}/auth/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name.trim(), email: email.trim(), password }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(data?.error || 'Đăng ký thất bại, vui lòng thử lại.');
    }
    if (!data?.token || !data?.user) {
      throw new Error('Phản hồi đăng ký không hợp lệ.');
    }
    localStorage.setItem('token', data.token);
    localStorage.setItem('smarthome_user', JSON.stringify(data.user));
    setCurrentUser(data.user);
    return data.user;
  };

  const logout = () => {
    localStorage.removeItem('token');
    localStorage.removeItem('smarthome_user');
    setCurrentUser(null);
  };

  return (
    <AuthContext.Provider
      value={{
        currentUser,
        isOwnerOrAdmin,
        syncUserProfile,
        login,
        register,
        logout,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) {
    throw new Error('useAuth must be used inside AuthProvider');
  }
  return ctx;
}