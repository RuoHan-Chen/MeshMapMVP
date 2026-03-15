package com.meshchat.mvp.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.*
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.ui.alerts.AlertFeedScreen
import com.meshchat.mvp.ui.chat.ChatScreen
import com.meshchat.mvp.ui.chat.PrivateChatScreen
import com.meshchat.mvp.ui.contacts.ContactsScreen
import com.meshchat.mvp.ui.dashboard.DashboardScreen
import com.meshchat.mvp.ui.map.MapScreen
import com.meshchat.mvp.ui.profile.ProfileScreen
import java.net.URLDecoder
import java.net.URLEncoder

sealed class Screen(val route: String, val label: String, val icon: ImageVector) {
    object Chat      : Screen("chat",      "Chat",      Icons.Filled.Chat)
    object Map       : Screen("map",       "Map",       Icons.Filled.Map)
    object Alerts    : Screen("alerts",    "Alerts",    Icons.Filled.Warning)
    object Dashboard : Screen("dashboard", "Dashboard", Icons.Filled.Dashboard)
    object Contacts  : Screen("contacts",  "Contacts",  Icons.Filled.People)
    object Profile   : Screen("profile",   "You",       Icons.Filled.AccountCircle)
}

private val topLevelScreens = listOf(
    Screen.Chat, Screen.Map, Screen.Alerts, Screen.Dashboard, Screen.Contacts, Screen.Profile
)

private fun encodeNavArg(s: String) = URLEncoder.encode(s, "UTF-8")
private fun decodeNavArg(s: String) = URLDecoder.decode(s, "UTF-8")

@Composable
fun MeshApp(mesh: BluetoothMeshService) {
    val navController  = rememberNavController()
    val contactUnread  by mesh.contactActivity.collectAsState()
    val unreadTotal    = contactUnread.values.sumOf { it.unread }

    fun navigateToPrivateChat(peerID: String, displayName: String) {
        navController.navigate(
            "private_chat/${encodeNavArg(peerID)}/${encodeNavArg(displayName)}"
        )
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                val navBackStackEntry by navController.currentBackStackEntryAsState()
                val currentDestination = navBackStackEntry?.destination
                topLevelScreens.forEach { screen ->
                    NavigationBarItem(
                        icon = {
                            when {
                                screen == Screen.Chat && unreadTotal > 0 ->
                                    BadgedBox(badge = { Badge { Text("$unreadTotal") } }) {
                                        Icon(screen.icon, screen.label)
                                    }
                                else -> Icon(screen.icon, screen.label)
                            }
                        },
                        label = { Text(screen.label) },
                        selected = currentDestination?.hierarchy?.any { it.route == screen.route } == true,
                        onClick = {
                            navController.navigate(screen.route) {
                                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    )
                }
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = Screen.Chat.route,
            modifier = Modifier.padding(innerPadding)
        ) {
            composable(Screen.Chat.route) {
                ChatScreen(mesh = mesh,
                    onNavigateToPrivateChat = { id, name -> navigateToPrivateChat(id, name) })
            }
            composable(Screen.Map.route)       { MapScreen(mesh = mesh) }
            composable(Screen.Alerts.route)    { AlertFeedScreen(mesh = mesh) }
            composable(Screen.Dashboard.route) { DashboardScreen(mesh = mesh) }
            composable(Screen.Contacts.route) {
                ContactsScreen(mesh = mesh,
                    onNavigateToPrivateChat = { id, name -> navigateToPrivateChat(id, name) })
            }
            composable(Screen.Profile.route)   { ProfileScreen(mesh = mesh) }
            composable("private_chat/{peerID}/{displayName}") { backStack ->
                val peerID      = decodeNavArg(backStack.arguments?.getString("peerID")      ?: "")
                val displayName = decodeNavArg(backStack.arguments?.getString("displayName") ?: peerID)
                PrivateChatScreen(mesh = mesh, peerID = peerID, displayName = displayName,
                    onBack = { navController.popBackStack() })
            }
        }
    }
}
