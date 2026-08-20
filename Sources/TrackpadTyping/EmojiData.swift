import Foundation

/// Curated emoji: six categories, each at most 30 entries so one category is
/// exactly one 10x3 grid page, plus single-word aliases that let a glided
/// word ("fire") offer its emoji as an extra candidate.
enum EmojiData {
    static let categories: [(icon: String, emoji: [String])] = [
        ("😀", ["😀","😂","🤣","😊","😍","🥰","😘","😎","🤔","😴",
                "😅","😉","🙃","😭","😢","😡","🤯","😱","🥳","😇",
                "🙄","😬","🤗","🤫","🤮","🥺","😤","💀","🤡","😷"]),
        ("👍", ["👍","👎","👏","🙏","🤝","💪","✌️","🤞","👌","🤙",
                "👋","🖐️","☝️","👇","🫶","🤷","🤦","🙋","💁","🧠",
                "👀","👂","🦶","💃","🕺","🏃","🧍","🫡","✊","🤌"]),
        ("❤️", ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","💔","💕",
                "💞","💛","✨","⭐","🌟","💥","🔥","⚡","💯","✅",
                "❌","❓","❗","💤","🎉","🎊","🏆","🥇","🎯","♻️"]),
        ("🐶", ["🐶","🐱","🐭","🐰","🦊","🐻","🐼","🐨","🦁","🐮",
                "🐷","🐸","🐵","🐔","🐧","🦆","🦅","🐴","🦄","🐝",
                "🦋","🐢","🐍","🐙","🦀","🐬","🐋","🌵","🌲","🌸"]),
        ("🍕", ["🍕","🍔","🍟","🌭","🌮","🍗","🥩","🍝","🍜","🍣",
                "🍎","🍌","🍉","🍇","🍓","🥑","🥦","🌽","🍞","🧀",
                "🍩","🍪","🎂","🍦","🍫","☕","🍺","🍷","🥤","🧊"]),
        ("⚽", ["⚽","🏀","🏈","⚾","🎾","🎮","🎲","🎸","🎹","🎧",
                "🚗","✈️","🚀","🚲","⌚","📱","💻","📷","💡","🔧",
                "🎁","📚","✏️","💰","🔑","🌍","☀️","🌙","☔","❄️"]),
    ]

    /// Glided word -> emoji. Only single glideable words, so a normal commit
    /// can carry its emoji as one extra chip.
    static let aliases: [String: String] = [
        "fire": "🔥", "heart": "❤️", "love": "❤️", "laugh": "😂", "lol": "😂",
        "haha": "😂", "cry": "😭", "sad": "😢", "happy": "😊", "smile": "😊",
        "cool": "😎", "wink": "😉", "angry": "😡", "shocked": "😱", "party": "🥳",
        "sleep": "😴", "sleepy": "😴", "think": "🤔", "thinking": "🤔",
        "skull": "💀", "dead": "💀", "clown": "🤡", "ghost": "👻",
        "thumbs": "👍", "yes": "👍", "no": "👎", "clap": "👏", "please": "🙏",
        "thanks": "🙏", "pray": "🙏", "strong": "💪", "muscle": "💪",
        "peace": "✌️", "wave": "👋", "eyes": "👀", "brain": "🧠",
        "dance": "💃", "run": "🏃", "shrug": "🤷", "salute": "🫡",
        "star": "⭐", "sparkle": "✨", "sparkles": "✨", "boom": "💥",
        "lightning": "⚡", "hundred": "💯", "check": "✅", "wrong": "❌",
        "question": "❓", "celebrate": "🎉", "confetti": "🎉", "trophy": "🏆",
        "target": "🎯", "dog": "🐶", "puppy": "🐶", "cat": "🐱", "kitty": "🐱",
        "mouse": "🐭", "rabbit": "🐰", "fox": "🦊", "bear": "🐻", "panda": "🐼",
        "lion": "🦁", "cow": "🐮", "pig": "🐷", "frog": "🐸", "monkey": "🐵",
        "chicken": "🐔", "penguin": "🐧", "duck": "🦆", "eagle": "🦅",
        "horse": "🐴", "unicorn": "🦄", "bee": "🐝", "butterfly": "🦋",
        "turtle": "🐢", "snake": "🐍", "octopus": "🐙", "crab": "🦀",
        "dolphin": "🐬", "whale": "🐋", "flower": "🌸", "tree": "🌲",
        "pizza": "🍕", "burger": "🍔", "fries": "🍟", "taco": "🌮",
        "pasta": "🍝", "ramen": "🍜", "sushi": "🍣", "apple": "🍎",
        "banana": "🍌", "watermelon": "🍉", "grapes": "🍇", "strawberry": "🍓",
        "avocado": "🥑", "bread": "🍞", "cheese": "🧀", "donut": "🍩",
        "cookie": "🍪", "cake": "🎂", "icecream": "🍦", "chocolate": "🍫",
        "coffee": "☕", "beer": "🍺", "wine": "🍷", "soccer": "⚽",
        "football": "🏈", "basketball": "🏀", "baseball": "⚾", "tennis": "🎾",
        "game": "🎮", "gaming": "🎮", "dice": "🎲", "guitar": "🎸",
        "music": "🎧", "car": "🚗", "plane": "✈️", "rocket": "🚀",
        "bike": "🚲", "phone": "📱", "laptop": "💻", "camera": "📷",
        "idea": "💡", "gift": "🎁", "book": "📚", "money": "💰", "key": "🔑",
        "world": "🌍", "earth": "🌍", "sun": "☀️", "moon": "🌙", "rain": "☔",
        "snow": "❄️", "poop": "💩", "robot": "🤖", "alien": "👽", "wow": "😮",
        "kiss": "😘", "hug": "🤗", "sick": "🤮", "mask": "😷", "ok": "👌",
    ]
}
