import React, { createContext, useState } from 'react';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import Login from './pages/Login';
import SellerDashboard from './pages/SellerDashboard';
import BuyerHome from './pages/BuyerHome';

export const AuthContext = createContext();

export default function App() {
  const [auth, setAuth] = useState({ token: null, role: null });
  return (
    <AuthContext.Provider value={{ auth, setAuth }}>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/seller" element={<SellerDashboard />} />
          <Route path="/buyer" element={<BuyerHome />} />
        </Routes>
      </BrowserRouter>
    </AuthContext.Provider>
  );
}