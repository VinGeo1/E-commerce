package com.ecommerce.controller;

import com.ecommerce.entity.Product;
import com.ecommerce.repository.ProductRepository;
import java.util.List;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Product catalogue. Reads are public (the buyer page works without a token); writes require a
 * SELLER token and, for updates, ownership of the row.
 */
@RestController
@RequestMapping("/products")
public class ProductController {

    private final ProductRepository productRepository;

    public ProductController(ProductRepository productRepository) {
        this.productRepository = productRepository;
    }

    /** GET /api/products - public list. */
    @GetMapping
    public List<Product> list() {
        return productRepository.findAll();
    }

    /** POST /api/products - SELLER only. Body: {name, price}. */
    @PostMapping
    @PreAuthorize("hasRole('SELLER')")
    public ResponseEntity<?> create(@RequestBody(required = false) Map<String, Object> body,
                                    Authentication authentication) {
        String name = text(body, "name");
        Double price = number(body, "price");
        if (name == null || price == null || price < 0) {
            return ResponseEntity.badRequest()
                .body(Map.of("message", "name (string) and price (number >= 0) are required"));
        }

        Product product = new Product();
        product.setName(name);
        product.setPrice(price);
        // seller_id always comes from the token, never from the request body.
        product.setSellerId(userId(authentication));

        return ResponseEntity.status(HttpStatus.CREATED).body(productRepository.save(product));
    }

    /** PUT /api/products/{id} - SELLER only, updates price (and name when supplied). */
    @PutMapping("/{id}")
    @PreAuthorize("hasRole('SELLER')")
    public ResponseEntity<?> update(@PathVariable Long id,
                                   @RequestBody(required = false) Map<String, Object> body,
                                   Authentication authentication) {
        Double price = number(body, "price");
        String name = text(body, "name");
        if (price == null && name == null) {
            return ResponseEntity.badRequest()
                .body(Map.of("message", "provide price (number) and/or name (string)"));
        }

        Product existing = productRepository.findById(id).orElse(null);
        if (existing == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(Map.of("message", "no product with id " + id));
        }

        Long callerId = userId(authentication);
        if (callerId != null && existing.getSellerId() != null && !callerId.equals(existing.getSellerId())) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN)
                .body(Map.of("message", "only the listing seller may edit this product"));
        }

        if (price != null) {
            if (price < 0) {
                return ResponseEntity.badRequest().body(Map.of("message", "price must be >= 0"));
            }
            existing.setPrice(price);
        }
        if (name != null) {
            existing.setName(name);
        }
        return ResponseEntity.ok(productRepository.save(existing));
    }

    /** The JWT filter stores the user id in Authentication#getCredentials(). */
    private static Long userId(Authentication authentication) {
        if (authentication == null) {
            return null;
        }
        Object credentials = authentication.getCredentials();
        return credentials instanceof Number number ? number.longValue() : null;
    }

    private static String text(Map<String, Object> body, String key) {
        Object value = body == null ? null : body.get(key);
        if (value == null || String.valueOf(value).isBlank()) {
            return null;
        }
        return String.valueOf(value).trim();
    }

    private static Double number(Map<String, Object> body, String key) {
        Object value = body == null ? null : body.get(key);
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        if (value instanceof String text && !text.isBlank()) {
            try {
                return Double.parseDouble(text.trim());
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        return null;
    }
}
