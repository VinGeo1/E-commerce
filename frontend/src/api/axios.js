import axios from 'axios';

// Built with REACT_APP_API_URL (see frontend/Dockerfile); empty means "same origin",
// which is what the ALB gives us: it forwards /api/* to the backend service.
const baseURL = process.env.REACT_APP_API_URL || '/api';

const api = axios.create({ baseURL });

api.interceptors.request.use((config) => {
  const token = localStorage.getItem('token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

api.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response && error.response.status === 401) {
      localStorage.removeItem('token');
      localStorage.removeItem('user');
      if (window.location.pathname !== '/login') {
        window.location.assign('/login');
      }
    }
    return Promise.reject(error);
  }
);

export function readStoredSession() {
  const token = localStorage.getItem('token');
  if (!token) {
    return { token: null, user: null };
  }
  try {
    return { token, user: JSON.parse(localStorage.getItem('user') || 'null') };
  } catch (err) {
    return { token, user: null };
  }
}

export function storeSession(token, user) {
  localStorage.setItem('token', token);
  localStorage.setItem('user', JSON.stringify(user || null));
}

export function clearSession() {
  localStorage.removeItem('token');
  localStorage.removeItem('user');
}

export function errorMessage(err, fallback) {
  const data = err && err.response && err.response.data;
  if (data && typeof data === 'object') {
    return data.message || data.error || JSON.stringify(data);
  }
  if (typeof data === 'string' && data.length < 200) {
    return data;
  }
  return fallback;
}

export default api;
