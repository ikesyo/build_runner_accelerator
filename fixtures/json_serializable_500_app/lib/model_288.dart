import 'package:json_annotation/json_annotation.dart';

part 'model_288.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model288 {
  const Model288({required this.id, required this.value});

  final int id;
  final String value;

  factory Model288.fromJson(Map<String, dynamic> json) =>
      _$Model288FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model288ToJson(this);
}
