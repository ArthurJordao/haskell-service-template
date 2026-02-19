const AUTH_URL = import.meta.env.VITE_AUTH_URL as string

async function tryRefresh(): Promise<boolean> {
  const refreshToken = localStorage.getItem('refresh_token')
  if (!refreshToken) return false
  try {
    const res = await fetch(`${AUTH_URL}/auth/refresh`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refreshToken }),
    })
    if (!res.ok) return false
    const data = await res.json()
    localStorage.setItem('access_token', data.accessToken)
    localStorage.setItem('refresh_token', data.refreshToken)
    return true
  } catch {
    return false
  }
}

function clearSession() {
  localStorage.removeItem('access_token')
  localStorage.removeItem('refresh_token')
  window.location.href = '/login'
}

export async function apiFetch<T>(baseUrl: string, path: string, init: RequestInit = {}): Promise<T> {
  const makeHeaders = () => {
    const token = localStorage.getItem('access_token')
    return {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(init.headers ?? {}),
    }
  }

  let res = await fetch(`${baseUrl}${path}`, { ...init, headers: makeHeaders() })

  if (res.status === 401) {
    const refreshed = await tryRefresh()
    if (refreshed) {
      res = await fetch(`${baseUrl}${path}`, { ...init, headers: makeHeaders() })
    }
    if (res.status === 401) {
      clearSession()
      throw new Error('Session expired')
    }
  }

  if (!res.ok) {
    const body = await res.text().catch(() => res.statusText)
    throw new Error(`${res.status}: ${body}`)
  }

  const text = await res.text()
  if (!text) return undefined as T
  return JSON.parse(text) as T
}
