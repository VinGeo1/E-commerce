import React, { useState, useEffect } from 'react';
import api from '../api/axios';

export default function BuyerHome() {
  const [products, setProducts] = useState([]);

  useEffect(() => { api.get('/products').then(res => setProducts(res.data)); }, []);

  const handleBuy = (productId) => {
    api.post('/orders', { productId, quantity: 1 });
  };

  return (
    <div>
      <h1>Products</h1>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr' }}>
        {products.map(p => (
          <div key={p.id}>
            <h3>{p.name}</h3>
            <p>${p.price}</p>
            <button onClick={() => handleBuy(p.id)}>Buy</button>
          </div>
        ))}
      </div>
    </div>
  );
}