import React, { useCallback, useEffect, useState } from 'react';
import { errorMessage } from '../api/axios';
import api from '../api/axios';

export default function BuyerHome() {
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [note, setNote] = useState(null);

  const load = useCallback(() => {
    setLoading(true);
    api
      .get('/products')
      .then((res) => setProducts(Array.isArray(res.data) ? res.data : []))
      .catch((err) => setNote({ kind: 'error', text: errorMessage(err, 'Could not load products') }))
      .finally(() => setLoading(false));
  }, []);

  useEffect(load, [load]);

  // TODO(orders): the backend has an Order entity but no /api/orders controller yet
  // (see backend/src/main/java/com/ecommerce/entity/Order.java), so checkout is
  // reported instead of silently POSTing to a missing endpoint.
  const handleBuy = (product) => {
    setNote({
      kind: 'notice',
      text: `Checkout for "${product.name}" is not implemented in this skeleton - add an OrderController to wire it up.`,
    });
  };

  return (
    <>
      <h1>Products</h1>
      {note && <p className={note.kind === 'error' ? 'error' : 'notice'}>{note.text}</p>}
      {loading && <p className="muted">Loading catalogue…</p>}
      {!loading && products.length === 0 && (
        <p className="muted">
          No products yet. A seller can add some from the Seller dashboard.
        </p>
      )}
      <ul className="grid">
        {products.map((product) => (
          <li className="card" key={product.id}>
            <strong>{product.name}</strong>
            <div className="price">${Number(product.price).toFixed(2)}</div>
            <button type="button" onClick={() => handleBuy(product)}>Buy</button>
          </li>
        ))}
      </ul>
      <div className="row" style={{ marginTop: '1rem' }}>
        <button type="button" className="secondary" onClick={load}>Refresh</button>
      </div>
    </>
  );
}
