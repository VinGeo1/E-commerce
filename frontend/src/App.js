import React, { createContext, useContext, useMemo } from 'react';
import { BrowserRouter, Link, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { clearSession, readStoredSession } from './api/axios';
import BuyerHome from './pages/BuyerHome';
import Login from './pages/Login';
import SellerDashboard from './pages/SellerDashboard';

export const AuthContext = createContext(null);

export function useAuth() {
  return useContext(AuthContext);
}

function Nav() {
  const { session } = useAuth();
  const location = useLocation();
  const role = session.user && session.user.role;

  const signOut = () => {
    clearSession();
    window.location.assign('/login');
  };

  const linkClass = (path) => (location.pathname === path ? 'active' : undefined);

  return (
    <nav className="topbar">
      <Link to="/" className={linkClass('/')}>Browse</Link>
      {role === 'SELLER' && <Link to="/seller" className={linkClass('/seller')}>Seller dashboard</Link>}
      <span className="spacer" />
      {session.token ? (
        <>
          <span className="who">{session.user ? `${session.user.email} (${role})` : 'signed in'}</span>
          <button className="secondary" onClick={signOut} type="button">Sign out</button>
        </>
      ) : (
        <Link to="/login" className={linkClass('/login')}>Sign in</Link>
      )}
    </nav>
  );
}

function RequireRole({ role, children }) {
  const { session } = useAuth();
  if (!session.token) {
    return <Navigate to="/login" replace />;
  }
  if (role && session.user && session.user.role !== role) {
    return (
      <div className="notice">
        You are signed in as {session.user.role}. This page needs a {role} account - sign in with
        one, or create it from the Sign up tab.
      </div>
    );
  }
  return children;
}

export default function App() {
  // Read once on mount; the interceptors in api/axios.js attach the token per request.
  const value = useMemo(() => ({ session: readStoredSession() }), []);

  return (
    <AuthContext.Provider value={value}>
      <BrowserRouter>
        <Nav />
        <main>
          <Routes>
            <Route path="/" element={<BuyerHome />} />
            <Route path="/login" element={<Login />} />
            <Route
              path="/seller"
              element={
                <RequireRole role="SELLER">
                  <SellerDashboard />
                </RequireRole>
              }
            />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      </BrowserRouter>
    </AuthContext.Provider>
  );
}
