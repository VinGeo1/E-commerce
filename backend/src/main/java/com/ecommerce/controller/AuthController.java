package com.ecommerce.controller;

import com.ecommerce.config.SecurityConfig;
import com.ecommerce.entity.User;
import com.ecommerce.repository.UserRepository;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Email + password signup / sign-in returning a JWT.
 *
 * <p>TODO(auth): OTP and Google sign-in are deliberately stubbed (see the 501 handlers at the
 * bottom). This repo is a deployment skeleton; the goal is a working ECS service, not a
 * production identity provider.
 */
@RestController
@RequestMapping("/auth")
public class AuthController {

    private static final int MIN_PASSWORD_LENGTH = 8;

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final SecurityConfig tokens;

    public AuthController(UserRepository userRepository, PasswordEncoder passwordEncoder,
                          SecurityConfig tokens) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.tokens = tokens;
    }

    /** POST /api/auth/signup - {email, password, role?} -> 201 {id, email, role}. */
    @PostMapping("/signup")
    public ResponseEntity<Map<String, Object>> signup(@RequestBody(required = false) Map<String, String> body) {
        String email = trim(body, "email");
        String password = body == null ? null : body.get("password");
        String role = trim(body, "role");

        if (email == null || !email.contains("@")) {
            return error(HttpStatus.BAD_REQUEST, "email is required and must contain '@'");
        }
        if (password == null || password.length() < MIN_PASSWORD_LENGTH) {
            return error(HttpStatus.BAD_REQUEST, "password must be at least " + MIN_PASSWORD_LENGTH + " characters");
        }
        if (userRepository.existsByEmailIgnoreCase(email)) {
            return error(HttpStatus.CONFLICT, "an account with that email already exists");
        }

        String normalisedRole = (role == null ? "BUYER" : role.toUpperCase(Locale.ROOT));
        if (!normalisedRole.equals("BUYER") && !normalisedRole.equals("SELLER")) {
            return error(HttpStatus.BAD_REQUEST, "role must be BUYER or SELLER");
        }

        User user = new User();
        user.setEmail(email);
        user.setPassword(passwordEncoder.encode(password));
        user.setRole(normalisedRole);
        User saved = userRepository.save(user);

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("id", saved.getId());
        response.put("email", saved.getEmail());
        response.put("role", saved.getRole());
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    /** POST /api/auth/signin - {email, password} -> {token, role, ...}. */
    @PostMapping("/signin")
    public ResponseEntity<Map<String, Object>> signin(@RequestBody(required = false) Map<String, String> body) {
        String email = trim(body, "email");
        String password = body == null ? null : body.get("password");
        if (email == null || password == null) {
            return error(HttpStatus.BAD_REQUEST, "email and password are required");
        }

        return userRepository.findByEmailIgnoreCase(email)
            .filter(user -> passwordEncoder.matches(password, user.getPassword()))
            .map(user -> {
                Map<String, Object> response = new LinkedHashMap<>();
                response.put("token", tokens.generateToken(user.getId(), user.getEmail(), user.getRole()));
                response.put("tokenType", "Bearer");
                response.put("id", user.getId());
                response.put("email", user.getEmail());
                response.put("role", user.getRole());
                return ResponseEntity.ok(response);
            })
            // Same answer for "no such user" and "wrong password" - do not enumerate accounts.
            .orElseGet(() -> error(HttpStatus.UNAUTHORIZED, "invalid email or password"));
    }

    // ---------------------------------------------------------------------------------------
    // Stubs kept so the frontend buttons fail loudly instead of silently.
    // ---------------------------------------------------------------------------------------

    /** TODO(auth): implement with SNS Publish + a short-lived OTP row (hashed, TTL 5 min). */
    @PostMapping("/otp/request")
    public ResponseEntity<Map<String, Object>> requestOtp() {
        return error(HttpStatus.NOT_IMPLEMENTED,
            "OTP sign-in is not wired up in this skeleton; use POST /api/auth/signin");
    }

    /** TODO(auth): implement OTP verification here and return the same payload as /signin. */
    @PostMapping("/otp/verify")
    public ResponseEntity<Map<String, Object>> verifyOtp() {
        return error(HttpStatus.NOT_IMPLEMENTED,
            "OTP sign-in is not wired up in this skeleton; use POST /api/auth/signin");
    }

    /**
     * TODO(auth): Google OAuth - add spring-boot-starter-oauth2-client, set
     * spring.security.oauth2.client.registration.google.* from Secrets Manager and
     * .oauth2Login(...) in SecurityConfig, then redirect here.
     */
    @PostMapping("/google")
    public ResponseEntity<Map<String, Object>> google() {
        return error(HttpStatus.NOT_IMPLEMENTED,
            "Google OAuth is not wired up in this skeleton; use POST /api/auth/signin");
    }

    private static String trim(Map<String, String> body, String key) {
        String value = body == null ? null : body.get(key);
        if (value == null || value.isBlank()) {
            return null;
        }
        return value.trim();
    }

    private static ResponseEntity<Map<String, Object>> error(HttpStatus status, String message) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("error", status.value());
        body.put("message", message);
        return ResponseEntity.status(status).body(body);
    }
}
