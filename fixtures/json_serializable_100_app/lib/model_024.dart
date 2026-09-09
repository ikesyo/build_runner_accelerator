import 'package:json_annotation/json_annotation.dart';

part 'model_024.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model024 {
  const Model024({required this.id, required this.value});

  final int id;
  final String value;

  factory Model024.fromJson(Map<String, dynamic> json) =>
      _$Model024FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model024ToJson(this);
}
