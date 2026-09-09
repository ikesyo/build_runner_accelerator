import 'package:json_annotation/json_annotation.dart';

part 'model_027.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model027 {
  const Model027({required this.id, required this.value});

  final int id;
  final String value;

  factory Model027.fromJson(Map<String, dynamic> json) =>
      _$Model027FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model027ToJson(this);
}
