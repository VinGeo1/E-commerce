import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { errorMessage } from '../api/axios';
import api from '../api/axios';
import { useAuth } from '../App';

export default function SellerDashboard() {
  const { session } = useAuth();
  const sellerId = session.user && session.user.id;
  const [products, setProducts] = useState([]);
  const [draft, setDraft] = useState({ name: '', price: '' });
  const [prices, setPrices] = useState({});
  const [note, setNote] = useState(null);
  const [saving, setSaving] = useState(false);

  const load = useCallback(() => {
    api
      .get('/products')
      .then((res) => setProducts(Array.isArray(res.data) ? res.data : []))
      .catch((err) => setNote({ kind: 'error', text: errorMessage(err, 'Could not load products') }));
  }, []);

  useEffect(load, [load]);

  const mine = useMemo(
    () => (sellerId == null ? products : products.filter((p) => p.sellerId === sellerId)),
    [products, sellerId]
  );

  const addProduct = async (event) => {
    event.preventDefault();
    const price = Number(draft.price);
    if (!draft.name.trim() || Number.isNaN(price) || price < 0) {
      setNote({ kind: 'error', text: 'A name and a non-negative price are required.' });
      return;
    }
    setSaving(true);
    try {
      const { data } = await api.post('/products', { name: draft.name.trim(), price });
      setProducts((current) => [...current, data]);
      setDraft({ name: '', price: '' });
      setNote({ kind: 'notice', text: `Added "${data.name}".` });
    } catch (err) {
      setNote({ kind: 'error', text: errorMessage(err, 'Could not add the product') });
    } finally {
      setSaving(false);
    }
  };

  const savePrice = async (product) => {
    const price = Number(prices[product.id]);
    if (Number.isNaN(price) || price < 0) {
      setNote({ kind: 'error', text: 'Enter a non-negative price.' });
      return;
    }
    setSaving(true);
    try {
      // PUT /api/products/{id} - SELLER only, updates the price.
      const { data } = await api.put(`/products/${product.id}`, { price });
      setProducts((current) => current.map((p) => (p.id === data.id ? data : p)));
      setPrices({ ...prices, [data.id]: '' });
      setNote({ kind: 'notice', text: `Updated "${data.name}" to $${Number(data.price).toFixed(2)}.` });
    } catch (err) {
      setNote({ kind: 'error', text: errorMessage(err, 'Could not update the price') });
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <h1>Seller dashboard</h1>
      {note && <p className={note.kind === 'error' ? 'error' : 'notice'}>{note.text}</p>}

      <form className="card stack" onSubmit={addProduct} style={{ marginBottom: '1.25rem' }}>
        <div className="row" style={{ gap: '0.75rem', alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div style={{ flex: 2, minWidth: 180 }}>
            <label htmlFor="name">Product name</label>
            <input
              id="name"
              value={draft.name}
              onChange={(e) => setDraft({ ...draft, name: e.target.value })}
              placeholder="Wireless headphones"
            />
          </div>
          <div style={{ flex: 1, minWidth: 110 }}>
            <label htmlFor="price">Price (USD)</label>
            <input
              id="price"
              type="number"
              min="0"
              step="0.01"
              value={draft.price}
              onChange={(e) => setDraft({ ...draft, price: e.target.value })}
              placeholder="49.99"
            />
          </div>
          <button type="submit" disabled={saving}>Add product</button>
        </div>
      </form>

      <h2 style={{ fontSize: '1.05rem' }}>Your listings ({mine.length})</h2>
      {mine.length === 0 ? (
        <p className="muted">Nothing listed yet - add your first product above.</p>
      ) : (
        <ul className="bullet">
          {mine.map((product) => (
            <li className="card row" key={product.id} style={{ justifyContent: 'space-between' }}>
              <span>{product.name}</span>
              <span className="price">${Number(product.price).toFixed(2)}</span>
              <input
                aria-label={`New price for ${product.name}`}
                style={{ maxWidth: 110 }}
                type="number"
                min="0"
                step="0.01"
                placeholder="new price"
                value={prices[product.id] || ''}
                onChange={(e) => setPrices({ ...prices, [product.id]: e.target.value })}
              />
              <button type="button" onClick={() => savePrice(product)} disabled={saving}>Save</button>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
