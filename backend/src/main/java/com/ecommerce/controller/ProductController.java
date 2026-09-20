package com.ecommerce.controller;
import com.ecommerce.entity.Product;
import com.ecommerce.repository.ProductRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/products")
public class ProductController {

    @Autowired
    private ProductRepository productRepository;

    @GetMapping
    public List<Product> listProducts() { return productRepository.findAll(); }

    @PostMapping
    @PreAuthorize("hasRole('SELLER')")
    public Product createProduct(@RequestBody Product p) { return productRepository.save(p); }

    @PutMapping("/{id}/price")
    @PreAuthorize("hasRole('SELLER')")
    public Product updatePrice(@PathVariable Long id, @RequestBody Double price) {
        Product p = productRepository.findById(id).orElseThrow();
        p.setPrice(price);
        return productRepository.save(p);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasRole('SELLER')")
    public void deleteProduct(@PathVariable Long id) { productRepository.deleteById(id); }
}