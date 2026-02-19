import { createContext, useContext, useState, useEffect, type ReactNode } from 'react'
import { Navigate } from 'react-router-dom'

interface AuthContextValue {
  token: string | null
  login: (accessToken: string, refreshToken: string) => void
  logout: () => void
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [token, setToken] = useState<string | null>(() => localStorage.getItem('access_token'))

  useEffect(() => {
    if (token) {
      localStorage.setItem('access_token', token)
    } else {
      localStorage.removeItem('access_token')
      localStorage.removeItem('refresh_token')
    }
  }, [token])

  const login = (accessToken: string, refreshToken: string) => {
    localStorage.setItem('refresh_token', refreshToken)
    setToken(accessToken)
  }

  const logout = () => setToken(null)

  return <AuthContext.Provider value={{ token, login, logout }}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within AuthProvider')
  return ctx
}

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { token } = useAuth()
  if (!token) return <Navigate to="/login" replace />
  return <>{children}</>
}
