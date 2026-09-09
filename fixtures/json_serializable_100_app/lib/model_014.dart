import 'package:json_annotation/json_annotation.dart';

part 'model_014.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model014 {
  const Model014({required this.id, required this.value});

  final int id;
  final String value;

  factory Model014.fromJson(Map<String, dynamic> json) =>
      _$Model014FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model014ToJson(this);
}
