import 'package:json_annotation/json_annotation.dart';

part 'model_295.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model295 {
  const Model295({required this.id, required this.value});

  final int id;
  final String value;

  factory Model295.fromJson(Map<String, dynamic> json) =>
      _$Model295FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model295ToJson(this);
}
