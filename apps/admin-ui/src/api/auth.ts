import { apiFetch } from './client'
import type { TokenResponse } from '../types/in/Auth'

const AUTH_URL = import.meta.env.VITE_AUTH_URL as string

export async function login(email: string, password: string): Promise<TokenResponse> {
  return apiFetch<TokenResponse>(AUTH_URL, '/auth/login', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  })
}
