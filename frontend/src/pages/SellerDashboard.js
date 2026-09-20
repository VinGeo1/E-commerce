import React, { useState, useEffect } from 'react';
import api from '../api/axios';

export default function SellerDashboard() {
  const [products, setProducts] = useState([]);
  const [newProduct, setNewProduct] = useState({ name: '', price: 0 });

  useEffect(() => { api.get('/products').then(res => setProducts(res.data)); }, []);

  const handleAdd = async () => {
    await api.post('/products', newProduct);
    setProducts([...products, newProduct]);
  };

  const handlePriceUpdate = async (id, price) => {
    await api.put(`/products/${id}/price`, price);
  };

  return (
    <div>
      <h1>Seller Dashboard</h1>
      <input onChange={e => setNewProduct({...newProduct, name: e.target.value})} placeholder="Name" />
      <button onClick={handleAdd}>Add Product</button>
      {products.map(p => (
        <div key={p.id}>
          {p.name} - ${p.price}
          <button onClick={() => handlePriceUpdate(p.id, 100)}>Fix Price</button>
        </div>
      ))}
    </div>
  );
}