package com.ecommerce.controller;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/auth")
public class AuthController {

    @PostMapping("/otp/request")
    public void requestOtp(@RequestBody String email) {
        String otp = "123456";
        System.out.println("Sending OTP " + otp + " to " + email);
    }

    @PostMapping("/otp/verify")
    public String verifyOtp(@RequestBody String otp) {
        return "JWT_TOKEN_HERE";
    }
}