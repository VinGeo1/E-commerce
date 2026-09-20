import React, { useState } from 'react';
import { errorMessage, storeSession } from '../api/axios';
import api from '../api/axios';

export default function Login() {
  const [mode, setMode] = useState('signin');
  const [form, setForm] = useState({ email: '', password: '', role: 'BUYER' });
  const [status, setStatus] = useState({ busy: false, error: null, info: null });

  const set = (key) => (event) => setForm({ ...form, [key]: event.target.value });

  const submit = async (event) => {
    event.preventDefault();
    setStatus({ busy: true, error: null, info: null });
    try {
      const path = mode === 'signup' ? '/auth/signup' : '/auth/signin';
      const { data } = await api.post(path, form);
      if (mode === 'signup') {
        // /signup returns the account, not a token - sign in right away.
        const signedIn = await api.post('/auth/signin', { email: form.email, password: form.password });
        storeSession(signedIn.data.token, signedIn.data);
        window.location.assign(signedIn.data.role === 'SELLER' ? '/seller' : '/');
        return;
      }
      storeSession(data.token, data);
      window.location.assign(data.role === 'SELLER' ? '/seller' : '/');
    } catch (err) {
      setStatus({ busy: false, error: errorMessage(err, `${mode === 'signup' ? 'Sign up' : 'Sign in'} failed`), info: null });
    }
  };

  // OTP and Google are stubbed in AuthController on purpose.
  const callStub = async (path, label) => {
    setStatus({ busy: false, error: null, info: null });
    try {
      await api.post(path, { email: form.email });
    } catch (err) {
      setStatus({
        busy: false,
        error: null,
        info: `${label}: ${errorMessage(err, 'not implemented')}`,
      });
    }
  };

  return (
    <div className="card" style={{ maxWidth: 420, margin: '0 auto' }}>
      <h1>{mode === 'signup' ? 'Create your account' : 'Sign in'}</h1>

      <form className="stack" onSubmit={submit}>
        <div>
          <label htmlFor="email">Email</label>
          <input id="email" type="email" autoComplete="username" value={form.email} onChange={set('email')} required />
        </div>
        <div>
          <label htmlFor="password">Password</label>
          <input
            id="password"
            type="password"
            autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
            value={form.password}
            onChange={set('password')}
            minLength={8}
            required
          />
        </div>

        {mode === 'signup' && (
          <div>
            <label htmlFor="role">I want to</label>
            <select id="role" value={form.role} onChange={set('role')}>
              <option value="BUYER">Buy products</option>
              <option value="SELLER">Sell products</option>
            </select>
          </div>
        )}

        <button type="submit" disabled={status.busy}>
          {status.busy ? 'Working…' : mode === 'signup' ? 'Sign up' : 'Sign in'}
        </button>
      </form>

      <p className="muted">
        {mode === 'signup' ? 'Already have an account? ' : 'New here? '}
        <button
          type="button"
          className="secondary"
          onClick={() => setMode(mode === 'signup' ? 'signin' : 'signup')}
        >
          {mode === 'signup' ? 'Sign in' : 'Create an account'}
        </button>
      </p>

      {status.error && <p className="error">{status.error}</p>}
      {status.info && <p className="notice">{status.info}</p>}

      <hr style={{ margin: '1rem 0', border: 0, borderTop: '1px solid #e2e8f0' }} />
      <div className="row">
        <button type="button" className="secondary" onClick={() => callStub('/auth/otp/request', 'Email OTP')}>
          Send OTP
        </button>
        <button type="button" className="secondary" onClick={() => callStub('/auth/google', 'Google OAuth')}>
          Continue with Google
        </button>
      </div>
      <p className="muted">Both are stubs (HTTP 501) - see <code>AuthController</code> TODOs.</p>
    </div>
  );
}
