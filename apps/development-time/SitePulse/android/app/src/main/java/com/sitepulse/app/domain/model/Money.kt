package com.sitepulse.app.domain.model

import java.math.BigDecimal

/**
 * Represents a high-precision monetary amount in Turkish Lira (₺).
 * Strict BigDecimal usage prevents floating-point rounding errors per Constitution and STORY-01-01.
 */
data class Money(
    val amount: BigDecimal,
    val currency: String = "₺"
) {
    fun format(): String = "$currency$amount"

    operator fun plus(other: Money): Money {
        require(currency == other.currency) { "Cannot add amounts with different currencies: $currency vs ${other.currency}" }
        return Money(amount.add(other.amount), currency)
    }

    operator fun minus(other: Money): Money {
        require(currency == other.currency) { "Cannot subtract amounts with different currencies: $currency vs ${other.currency}" }
        return Money(amount.subtract(other.amount), currency)
    }

    companion object {
        val ZERO = Money(BigDecimal.ZERO)
        fun of(amount: BigDecimal, currency: String = "₺"): Money = Money(amount, currency)
        fun of(amountStr: String, currency: String = "₺"): Money = Money(BigDecimal(amountStr), currency)
    }
}
