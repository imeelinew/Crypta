<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Crypta">
</p>

<h1 align="center">Crypta</h1>

<p align="center">
  一个原生的 macOS 加密媒体库。<br>
  按保险箱分组管理视频与图片，本地加密存储、分级访问控制，以及一个漂亮的应用窗口。
</p>


<p align="center">
  <a href="https://github.com/imeelinew/Crypta/releases">下载</a> ·
  <a href="#安装">安装</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Crypta/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Crypta" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

---

<p align="center">
  <img alt="Crypta 加密媒体库窗口" src=".github/assets/app.png" width="800">
</p>

## 简介

Crypta 是一个优雅而原生的 macOS 加密媒体库，适合那些需要在本地妥善保管视频与图片、并且希望按主题或用途分开管理的人。

它用侧边栏组织多个「保险箱」，每个保险箱可以独立设置访问控制级别与媒体类型。需要查看时，通过 Touch ID 或系统密码解锁；播放与预览则在受控的临时会话中进行，离开应用或切换保险箱后自动上锁。

## 为什么开发 Crypta

系统自带的「照片」和 Finder 文件夹能存文件，但很难同时做到分组、加密、分级访问控制和安全的播放预览。Crypta 把这几件事合成一个轻量工具。

- **保险箱分组**：按课程、项目或用途创建多个保险箱，视频与图片分开管理。
- **分级访问控制**：标准、扩展、最高三档加密，按需选择是否要求设备认证、切换时上锁、失焦时上锁。
- **本地加密存储**：媒体文件与索引保存在本机 `Movies/Crypta.vault`，密钥存储在 Keychain。
- **安全播放与预览**：受保护保险箱内建播放器，失焦时自动遮挡画面；支持 Quick Look 空格预览。
- **导入与整理**：拖拽或文件选择器导入，支持重命名、排序、搜索、加密与解密导出。

## 保险箱

每个保险箱在创建时可选择：

- **访问控制级别**
  - **标准加密**：导入即加密，无需额外认证即可浏览与播放。
  - **扩展加密**：查看内容前需 Touch ID / 密码；可手动上锁，失焦后延迟自动上锁。
  - **最高加密**：每次进入都需认证；切换保险箱或应用失焦时立即上锁。
- **存储媒介**：视频或图片，各自支持对应的导入格式。

## 播放与预览

- **视频**：标准保险箱调用系统默认播放器；受保护保险箱使用内建播放器，并记住播放进度。
- **图片**：解密到临时会话后，用 Pixea 等外部应用打开。
- **Quick Look**：选中文件后按空格，或在列表中快速预览缩略图。
- **隐私保护**：播放器在应用失焦或保险箱上锁时自动暂停并遮挡画面。

## 其他功能

- 带缩略图的视频与图片列表
- 拖拽导入与多选批量操作
- 明文文件一键加密入库
- 解密导出到指定文件夹（导出后从库中移除）
- 索引备份与数据安全测试脚本
- 毛玻璃透明窗口，与 macOS 26 风格一致

## 安装

从 [Releases 页面](https://github.com/imeelinew/Crypta/releases) 下载最新版，把 `Crypta.app` 放到 `/Applications`。

## 从源码构建

需要 Xcode 与 macOS 26.5 或更高版本。

```bash
git clone https://github.com/imeelinew/Crypta.git
cd Crypta
open Crypta.xcodeproj
```

在 Xcode 中选择 **Crypta** scheme，然后 **Product → Run**。
