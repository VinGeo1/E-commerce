import React, { useContext, useState } from 'react';
import { AuthContext } from '../App';
import api from '../api/axios';

export default function Login() {
  const { setAuth } = useContext(AuthContext);
  const [otp, setOtp] = useState('');

  const handleGoogle = () => {
    window.location.href = 'http://localhost:8080/oauth2/authorization/google';
  };

  const handleOtp = async () => {
    try {
      const res = await api.post('/auth/otp/verify', { otp });
      setAuth({ token: res.data, role: 'BUYER' });
    } catch(err) { console.error(err); }
  };

  return (
    <div>
      <h1>Login</h1>
      <button onClick={handleGoogle}>Login with Google</button>
      <input type="text" placeholder="OTP" value={otp} onChange={e => setOtp(e.target.value)} />
      <button onClick={handleOtp}>Verify OTP</button>
    </div>
  );
}