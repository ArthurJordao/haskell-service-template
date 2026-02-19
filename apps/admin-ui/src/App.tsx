import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { Toaster } from '@/components/ui/sonner'
import { AuthProvider, ProtectedRoute } from './contexts/AuthContext'
import AdminLayout from './layouts/AdminLayout'
import LoginPage from './pages/LoginPage'
import DLQPage from './pages/DLQPage'

export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route
            path="/admin"
            element={
              <ProtectedRoute>
                <AdminLayout />
              </ProtectedRoute>
            }
          >
            <Route index element={<Navigate to="dlq" replace />} />
            <Route path="dlq" element={<DLQPage />} />
          </Route>
          <Route path="*" element={<Navigate to="/admin/dlq" replace />} />
        </Routes>
        <Toaster richColors />
      </AuthProvider>
    </BrowserRouter>
  )
}
