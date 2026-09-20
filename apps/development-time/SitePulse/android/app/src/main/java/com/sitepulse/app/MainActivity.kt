package com.sitepulse.app

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.sitepulse.app.ui.dashboard.DashboardScreen
import com.sitepulse.app.ui.dashboard.DashboardViewModel
import com.sitepulse.app.ui.theme.SitePulseTheme

class MainActivity : ComponentActivity() {
    private val viewModel: DashboardViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SitePulseTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    DashboardScreen(
                        viewModel = viewModel,
                        onPayClick = {
                            Toast.makeText(
                                this,
                                "Kredi kartı 3D Secure ödeme akışı başlatılıyor...",
                                Toast.LENGTH_LONG
                            ).show()
                        },
                        onActionClick = { action ->
                            Toast.makeText(
                                this,
                                "$action modülü açılıyor...",
                                Toast.LENGTH_SHORT
                            ).show()
                        }
                    )
                }
            }
        }
    }
}
