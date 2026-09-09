import 'package:json_annotation/json_annotation.dart';

part 'model_311.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model311 {
  const Model311({required this.id, required this.value});

  final int id;
  final String value;

  factory Model311.fromJson(Map<String, dynamic> json) =>
      _$Model311FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model311ToJson(this);
}
