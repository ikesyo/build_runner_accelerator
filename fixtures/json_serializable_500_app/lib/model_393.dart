import 'package:json_annotation/json_annotation.dart';

part 'model_393.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model393 {
  const Model393({required this.id, required this.value});

  final int id;
  final String value;

  factory Model393.fromJson(Map<String, dynamic> json) =>
      _$Model393FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model393ToJson(this);
}
