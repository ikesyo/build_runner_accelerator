import 'package:json_annotation/json_annotation.dart';

part 'model_117.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model117 {
  const Model117({required this.id, required this.value});

  final int id;
  final String value;

  factory Model117.fromJson(Map<String, dynamic> json) =>
      _$Model117FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model117ToJson(this);
}
