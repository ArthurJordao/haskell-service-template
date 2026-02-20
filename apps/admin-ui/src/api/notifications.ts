import { apiFetch } from './client'
import type { SentNotification } from '../types/in/Notifications'

const NOTIFICATION_URL = import.meta.env.VITE_NOTIFICATION_URL as string

export async function listNotifications(recipient: string): Promise<SentNotification[]> {
  const query = new URLSearchParams({ recipient })
  return apiFetch<SentNotification[]>(NOTIFICATION_URL, `/notifications?${query}`)
}
