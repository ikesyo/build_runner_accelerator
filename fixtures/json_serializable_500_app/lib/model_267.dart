import 'package:json_annotation/json_annotation.dart';

part 'model_267.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model267 {
  const Model267({required this.id, required this.value});

  final int id;
  final String value;

  factory Model267.fromJson(Map<String, dynamic> json) =>
      _$Model267FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model267ToJson(this);
}
