package metis.gateway.runtime

public func gatewayDashboardMethodAlias(method: String): String {
    match (method.trimAscii().toAsciiLower()) {
        case "health" => "dashboard.status"
        case "health.get" => "dashboard.status"
        case "chat.history" => "dashboard.chat.history"
        case "chat.send" => "dashboard.chat.send"
        case "models" => "dashboard.models"
        case "models.list" => "dashboard.models"
        case "skills" => "skills.status"
        case "skills.list" => "skills.status"
        case "skills.compatibility" => "skills.compatibilityMatrix"
        case "nodes.canvas.present" => "node.invoke"
        case "nodes.canvas.snapshot" => "node.invoke"
        case "nodes.canvas.navigate" => "node.invoke"
        case "nodes.canvas.eval" => "node.invoke"
        case "nodes.canvas.a2ui_push" => "node.invoke"
        case "nodes.canvas.a2ui_reset" => "node.invoke"
        case _ => ""
    }
}
