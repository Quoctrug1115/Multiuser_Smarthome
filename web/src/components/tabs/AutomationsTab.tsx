import React, { useState } from 'react';
import type { AutomationRule } from '../../types/smarthome';
import { API_BASE, getAuthHeaders } from '../../utils/api';

interface AutomationsTabProps {
  automations: AutomationRule[];
  setAutomations: React.Dispatch<React.SetStateAction<AutomationRule[]>>;
  isOwnerOrAdmin: boolean;
  cardBg: string;
  inputBg: string;
  appendLog: (msg: string) => void;
  onRefresh: () => Promise<void>;
}

export function AutomationsTab({
  automations,
  setAutomations,
  isOwnerOrAdmin,
  cardBg,
  inputBg,
  appendLog,
  onRefresh,
}: AutomationsTabProps) {
  const [newAutoName, setNewAutoName] = useState('');
  const [newAutoCondition, setNewAutoCondition] = useState('');
  const [newAutoAction, setNewAutoAction] = useState('');

  const handleCreateAutomation = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newAutoName.trim() || !newAutoCondition.trim() || !newAutoAction.trim()) return;

    const res = await fetch(`${API_BASE}/automations`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        name: newAutoName.trim(),
        condition_text: newAutoCondition.trim(),
        action_text: newAutoAction.trim(),
      }),
    });

    if (res.ok) {
      appendLog(`Đã tạo kịch bản "${newAutoName.trim()}".`);
      setNewAutoName('');
      setNewAutoCondition('');
      setNewAutoAction('');
      onRefresh();
    }
  };

  const handleToggleAutomation = async (rule: AutomationRule) => {
    const next = !rule.is_active;
    setAutomations((prev) =>
      prev.map((a) => (a.id === rule.id ? { ...a, is_active: next } : a))
    );
    await fetch(`${API_BASE}/automations/${rule.id}/toggle`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({ is_active: next }),
    });
  };

  const handleDeleteAutomation = async (rule: AutomationRule) => {
    if (!confirm(`Xóa kịch bản "${rule.name}"?`)) return;
    const res = await fetch(`${API_BASE}/automations/${rule.id}`, {
      method: 'DELETE',
      headers: getAuthHeaders(),
    });
    if (res.ok) {
      appendLog(`Đã xóa kịch bản "${rule.name}".`);
      onRefresh();
    }
  };

  return (
    <div className="space-y-6">
      {isOwnerOrAdmin && (
        <form
          onSubmit={handleCreateAutomation}
          className={`p-5 rounded-2xl border grid grid-cols-1 md:grid-cols-4 gap-3 items-end ${cardBg}`}
        >
          <div>
            <label className="block text-xs text-slate-400 mb-1">Tên kịch bản</label>
            <input
              type="text"
              required
              value={newAutoName}
              onChange={(e) => setNewAutoName(e.target.value)}
              placeholder="VD: Tự động làm mát"
              className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
            />
          </div>
          <div>
            <label className="block text-xs text-slate-400 mb-1">Điều kiện (IF)</label>
            <input
              type="text"
              required
              value={newAutoCondition}
              onChange={(e) => setNewAutoCondition(e.target.value)}
              placeholder="VD: temperature > 30"
              className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
            />
          </div>
          <div>
            <label className="block text-xs text-slate-400 mb-1">Hành động (THEN)</label>
            <input
              type="text"
              required
              value={newAutoAction}
              onChange={(e) => setNewAutoAction(e.target.value)}
              placeholder="VD: Bật quạt phòng khách"
              className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
            />
          </div>
          <button
            type="submit"
            className="py-2 px-4 rounded-xl bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs"
          >
            + Thêm Kịch bản
          </button>
        </form>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {automations.length === 0 ? (
          <div
            className={`col-span-full p-10 rounded-2xl border text-center text-xs text-slate-500 ${cardBg}`}
          >
            Chưa có kịch bản tự động hóa nào trong ngôi nhà của bạn.
          </div>
        ) : (
          automations.map((rule) => (
            <div
              key={rule.id}
              className={`p-4 rounded-2xl border flex items-center justify-between gap-3 ${cardBg}`}
            >
              <div>
                <div className="font-bold text-sm">{rule.name}</div>
                <div className="text-xs text-slate-400 mt-1">
                  IF <span className="text-amber-400 font-mono">{rule.condition_text}</span> → THEN{' '}
                  <span className="text-cyan-400">{rule.action_text}</span>
                </div>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <button
                  onClick={() => handleToggleAutomation(rule)}
                  className={`px-3 py-1.5 rounded-lg text-xs font-bold ${
                    rule.is_active
                      ? 'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30'
                      : 'bg-slate-800 text-slate-400'
                  }`}
                >
                  {rule.is_active ? 'Đang BẬT' : 'Đang TẮT'}
                </button>
                {isOwnerOrAdmin && (
                  <button
                    onClick={() => handleDeleteAutomation(rule)}
                    className="px-2.5 py-1.5 rounded-lg bg-rose-500/15 text-rose-400 hover:bg-rose-500/25 text-xs"
                  >
                    Xóa
                  </button>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}