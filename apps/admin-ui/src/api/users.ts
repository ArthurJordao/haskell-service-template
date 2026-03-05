import { apiFetch } from './client'
import type { ScopeInfo, UserWithScopes } from '../types/in/Users'

const AUTH_URL = import.meta.env.VITE_AUTH_URL as string

export async function listScopes(): Promise<ScopeInfo[]> {
  return apiFetch<ScopeInfo[]>(AUTH_URL, '/scopes')
}

export async function listUsers(): Promise<UserWithScopes[]> {
  return apiFetch<UserWithScopes[]>(AUTH_URL, '/users')
}

export async function getUserScopes(userId: number): Promise<string[]> {
  return apiFetch<string[]>(AUTH_URL, `/users/${userId}/scopes`)
}

export async function setUserScopes(userId: number, scopes: string[]): Promise<void> {
  return apiFetch<void>(AUTH_URL, `/users/${userId}/scopes`, {
    method: 'PUT',
    body: JSON.stringify({ scopes }),
  })
}
